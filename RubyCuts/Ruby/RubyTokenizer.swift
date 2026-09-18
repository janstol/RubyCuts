/// One colored span of Ruby source, as produced by ``RubyTokenizer``.
///
/// Only spans that get a color exist as tokens: plain identifiers, operators
/// and punctuation are never emitted and keep the editor's default color.
/// Opted out of the app target's MainActor-by-default isolation, matching
/// ``RunInput`` and the gem value types: a pure value with no actor-coupled
/// state, usable from the nonisolated test target.
nonisolated struct RubyToken: Equatable, Sendable {
    /// What a token is, which is all the highlighter needs to pick a color.
    nonisolated enum Kind: Equatable, Sendable {
        case comment
        case keyword
        case string
        case symbol
        case number
        case constant
        case variable
    }

    let kind: Kind

    /// UTF-8 byte offsets into the tokenized source. Byte offsets rather
    /// than `String.Index` so the tokenizer never touches the source's
    /// grapheme breaking, and so ``RubySyntaxHighlighting`` can map them onto
    /// an `AttributedString` through its `utf8` view in one forward walk.
    let range: Range<Int>
}

/// A single-pass, heuristic Ruby lexer for syntax highlighting.
///
/// Scans the source's UTF-8 bytes once and emits ``RubyToken``s for
/// comments, string-like literals (strings, heredocs, `%` literals, regex
/// literals), symbols and hash labels, numbers, reserved words, constants
/// and `@`/`$` variables. It is deliberately not a parser: the two places
/// Ruby's grammar is genuinely ambiguous at the byte level, `/` (regex vs.
/// division) and bare `<<` (heredoc vs. shift), are settled with the usual
/// editor heuristics documented on the private scanner below. Getting one
/// wrong miscolors a span, nothing more.
///
/// Unterminated literals run to the end of input, so a string that is still
/// being typed colors as a string until it's closed. Bytes at or above
/// `0x80` count as identifier characters, so non-ASCII text in strings,
/// comments and names flows through without special handling.
///
/// Pure and VM-free (the embedded Ruby is a serialized executor that's busy
/// during runs; the wrong tool for a keystroke path), so it is unit-tested
/// directly in `RubyTokenizerTests`.
nonisolated enum RubyTokenizer {
    /// Tokenizes `source`. Tokens come back sorted by position and never
    /// overlap.
    static func tokenize(_ source: String) -> [RubyToken] {
        var scanner = Scanner(bytes: Array(source.utf8))
        scanner.scan()
        return scanner.tokens
    }
}

// MARK: - Scanner

/// The byte-level cursor behind ``RubyTokenizer/tokenize(_:)``. Each
/// `scan…` method is entered with `position` on the byte that triggered it
/// and leaves `position` just past whatever it consumed.
nonisolated private struct Scanner {
    let bytes: [UInt8]
    var position = 0
    var tokens: [RubyToken] = []

    /// Heredocs opened on the current line. Their bodies start on the next
    /// line and are consumed, in opening order, once that line's newline is
    /// reached.
    var pendingHeredocs: [Heredoc] = []

    nonisolated struct Heredoc {
        let terminator: [UInt8]
        /// `<<~` and `<<-` let the terminator line be indented.
        let allowsIndentedTerminator: Bool
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    // MARK: Main loop

    mutating func scan() {
        while position < bytes.count {
            scanNext()
        }
    }

    private mutating func scanNext() {
        let byte = bytes[position]
        if byte == .newline {
            position += 1
            if !pendingHeredocs.isEmpty {
                scanHeredocBodies()
            }
            return
        }

        let atLineStart = position == 0 || bytes[position - 1] == .newline
        if atLineStart {
            if hasPrefix(Markers.beginComment) && isBlank(at: position + Markers.beginComment.count)
            {
                scanBlockComment()
                return
            }
            if hasPrefix(Markers.dataSection) && isLineEnd(at: position + Markers.dataSection.count)
            {
                emit(.comment, position..<bytes.count)
                position = bytes.count
                return
            }
        }

        switch byte {
        case .hash:
            scanLineComment()
        case .singleQuote:
            let start = position
            skipDelimited(open: .singleQuote, close: .singleQuote, interpolates: false)
            emit(.string, start..<position)
        case .doubleQuote, .backtick:
            let start = position
            skipDelimited(open: byte, close: byte, interpolates: true)
            emit(.string, start..<position)
        case .percent:
            if !scanPercentLiteral() { position += 1 }
        case .slash:
            if isRegexPosition() { scanRegex() } else { position += 1 }
        case .lessThan:
            if !scanHeredocOpener() { position += 1 }
        case .colon:
            scanColon()
        case .at:
            scanInstanceVariable()
        case .dollar:
            scanGlobalVariable()
        case _ where byte.isDigit:
            scanNumber()
        case _ where byte.isIdentifierStart:
            scanWord()
        default:
            position += 1
        }
    }

    // MARK: Comments

    /// `#` through the end of the line, newline excluded.
    private mutating func scanLineComment() {
        let start = position
        position = lineEnd(from: position)
        emit(.comment, start..<position)
    }

    /// `=begin` at a line start through the end of the line that starts
    /// with `=end`, or to the end of input when there is none.
    private mutating func scanBlockComment() {
        let start = position
        position = lineEnd(from: position)
        while position < bytes.count {
            position += 1  // the newline
            if hasPrefix(Markers.endComment) {
                position = lineEnd(from: position)
                emit(.comment, start..<position)
                return
            }
            position = lineEnd(from: position)
        }
        emit(.comment, start..<position)
    }

    // MARK: Strings

    /// Advances past a literal opened by `open` and closed by `close`, both
    /// already known to be at or ahead of `position` (the opener itself is
    /// consumed here). Backslash escapes the next byte. When `open` and
    /// `close` differ, matching pairs nest (`%q(a (b) c)`). When
    /// `interpolates`, a `#{…}` span is skipped by brace depth so a closing
    /// delimiter inside an interpolation doesn't end the literal. Runs to
    /// the end of input when unterminated.
    private mutating func skipDelimited(open: UInt8, close: UInt8, interpolates: Bool) {
        position += 1
        var depth = 1
        var interpolationDepth = 0
        while position < bytes.count {
            let byte = bytes[position]
            if byte == .backslash {
                position += 2
                continue
            }
            if interpolationDepth > 0 {
                if byte == .leftBrace {
                    interpolationDepth += 1
                } else if byte == .rightBrace {
                    interpolationDepth -= 1
                }
                position += 1
                continue
            }
            if interpolates && byte == .hash && peek(1) == .leftBrace {
                interpolationDepth = 1
                position += 2
                continue
            }
            if open != close && byte == open {
                depth += 1
            } else if byte == close {
                depth -= 1
                if depth == 0 {
                    position += 1
                    return
                }
            }
            position += 1
        }
        position = bytes.count
    }

    /// `%w[…]`, `%i[…]`, `%q(…)`, `%Q{…}`, `%r{…}`, `%s`, `%x`, `%W`, `%I`
    /// and bare `%(…)`. Returns `false` (consuming nothing) when the `%` is
    /// the modulo operator instead: no valid delimiter follows, or the byte
    /// before it is an operand (`x%w[…]`, `10%3`, `f()%2`).
    private mutating func scanPercentLiteral() -> Bool {
        if position > 0 {
            let previous = bytes[position - 1]
            if previous.isIdentifierByte || previous == .rightParen || previous == .rightBracket
                || previous == .rightBrace
            {
                return false
            }
        }
        guard let next = peek(1) else { return false }
        let start = position
        let open: UInt8
        let interpolates: Bool
        if Markers.percentLiteralTypes.contains(next) {
            guard let delimiter = peek(2), delimiter.isPercentDelimiter else { return false }
            open = delimiter
            interpolates = Markers.interpolatingPercentTypes.contains(next)
            position += 2
        } else if Markers.barePercentDelimiters.contains(next) {
            open = next
            interpolates = true
            position += 1
        } else {
            return false
        }
        skipDelimited(open: open, close: open.matchingCloser, interpolates: interpolates)
        emit(.string, start..<position)
        return true
    }

    // MARK: Regex

    /// Whether a `/` at `position` opens a regex literal rather than being
    /// division: true at the start of input or a line, after one of
    /// `( , = ~ ! | & { [ ;`, or after one of the words in
    /// ``Markers/regexPrecedingWords``. Spaces and tabs before the `/` are
    /// ignored. The standard editor heuristic; cosmetic when wrong.
    private func isRegexPosition() -> Bool {
        var index = position - 1
        while index >= 0 && (bytes[index] == .space || bytes[index] == .tab) {
            index -= 1
        }
        guard index >= 0 else { return true }
        let previous = bytes[index]
        if previous == .newline || Markers.regexPrecedingBytes.contains(previous) {
            return true
        }
        guard previous.isIdentifierByte else { return false }
        var wordStart = index
        while wordStart > 0 && bytes[wordStart - 1].isIdentifierByte {
            wordStart -= 1
        }
        return Markers.regexPrecedingWords.contains(Array(bytes[wordStart...index]))
    }

    /// `/…/` plus any trailing flag letters, as one string-kind token.
    private mutating func scanRegex() {
        let start = position
        skipDelimited(open: .slash, close: .slash, interpolates: true)
        while let byte = peek(0), byte.isLowercaseLetter {
            position += 1
        }
        emit(.string, start..<position)
    }

    // MARK: Heredocs

    /// `<<~ID`, `<<-ID`, `<<ID`, with `ID` an identifier or a quoted one.
    /// The opener is emitted as a string token and the body is queued for
    /// ``scanHeredocBodies()``. Returns `false` (consuming nothing) when
    /// this `<` isn't a heredoc opener. A bare `<<` only counts when
    /// followed by a quote, an uppercase letter or `_`, so `a << b` and
    /// `a<<b` stay the shift/append operator.
    private mutating func scanHeredocOpener() -> Bool {
        guard peek(1) == .lessThan else { return false }
        var index = position + 2
        var indented = false
        if let modifier = at(index), modifier == .tilde || modifier == .minus {
            indented = true
            index += 1
        }
        guard let first = at(index) else { return false }
        let terminator: [UInt8]
        if first == .doubleQuote || first == .singleQuote || first == .backtick {
            let idStart = index + 1
            var idEnd = idStart
            while let byte = at(idEnd), byte != first, byte != .newline {
                idEnd += 1
            }
            guard idEnd > idStart, at(idEnd) == first else { return false }
            terminator = Array(bytes[idStart..<idEnd])
            index = idEnd + 1
        } else if first.isIdentifierStart
            && (indented || first.isUppercaseLetter || first == .underscore)
        {
            let idStart = index
            while let byte = at(index), byte.isIdentifierByte {
                index += 1
            }
            terminator = Array(bytes[idStart..<index])
        } else {
            return false
        }
        emit(.string, position..<index)
        pendingHeredocs.append(Heredoc(terminator: terminator, allowsIndentedTerminator: indented))
        position = index
        return true
    }

    /// Consumes the bodies of every heredoc opened on the line that just
    /// ended, in order. Each body, from the start of its first line through
    /// the end of its terminator line, is one string token; a body with no
    /// terminator runs to the end of input.
    private mutating func scanHeredocBodies() {
        let heredocs = pendingHeredocs
        pendingHeredocs.removeAll()
        for heredoc in heredocs {
            let bodyStart = position
            while position < bytes.count {
                let lineStart = position
                let end = lineEnd(from: lineStart)
                if isTerminatorLine(lineStart..<end, for: heredoc) {
                    emit(.string, bodyStart..<end)
                    position = min(end + 1, bytes.count)
                    break
                }
                position = min(end + 1, bytes.count)
            }
            if position >= bytes.count {
                emit(.string, bodyStart..<bytes.count)
                position = bytes.count
            }
        }
    }

    private func isTerminatorLine(_ line: Range<Int>, for heredoc: Heredoc) -> Bool {
        var start = line.lowerBound
        var end = line.upperBound
        if heredoc.allowsIndentedTerminator {
            while start < end && (bytes[start] == .space || bytes[start] == .tab) {
                start += 1
            }
        }
        if end > start && bytes[end - 1] == .carriageReturn {
            end -= 1
        }
        return bytes[start..<end].elementsEqual(heredoc.terminator)
    }

    // MARK: Symbols

    /// `:name` (with an optional `? ! =` suffix), `:"…"`, `:'…'`. A `::`
    /// is scope resolution and is skipped whole, so the constant after it
    /// is lexed on its own. A lone `:` (the ternary's) is skipped.
    private mutating func scanColon() {
        guard let next = peek(1) else {
            position += 1
            return
        }
        if next == .colon {
            position += 2
            return
        }
        let start = position
        if next == .doubleQuote || next == .singleQuote {
            position += 1
            skipDelimited(open: next, close: next, interpolates: next == .doubleQuote)
            emit(.symbol, start..<position)
            return
        }
        if next.isIdentifierStart {
            position += 1
            skipIdentifier()
            skipMethodNameSuffix()
            // A setter symbol (`:name=`), but not the first byte of `==`,
            // `=~` or `=>`. `after` is nil at end of input, which is fine.
            let after = peek(1)
            if peek(0) == .equals && after != .equals && after != .tilde && after != .greaterThan {
                position += 1
            }
            emit(.symbol, start..<position)
            return
        }
        position += 1
    }

    // MARK: Variables

    /// `@ivar` and `@@cvar`.
    private mutating func scanInstanceVariable() {
        let start = position
        var index = position + 1
        if at(index) == .at {
            index += 1
        }
        guard let first = at(index), first.isIdentifierStart else {
            position += 1
            return
        }
        position = index
        skipIdentifier()
        emit(.variable, start..<position)
    }

    /// `$gvar`, the numbered `$0`…`$9`, `$-w`-style two-letter globals,
    /// and the one-character specials like `$!` and `$stdout`'s siblings.
    private mutating func scanGlobalVariable() {
        let start = position
        guard let next = peek(1) else {
            position += 1
            return
        }
        if next.isIdentifierStart {
            position += 1
            skipIdentifier()
        } else if next.isDigit {
            position += 1
            while let byte = peek(0), byte.isDigit {
                position += 1
            }
        } else if next == .minus, let letter = peek(2), letter.isIdentifierByte {
            position += 3
        } else if Markers.specialGlobals.contains(next) {
            position += 2
        } else {
            position += 1
            return
        }
        emit(.variable, start..<position)
    }

    // MARK: Numbers

    /// Decimal with `_` separators, a fraction and an exponent; `0x`, `0b`,
    /// `0o`, `0d` prefixes; `r` and `i` suffixes.
    private mutating func scanNumber() {
        if position > 0 && bytes[position - 1].isIdentifierByte {
            position += 1
            return
        }
        let start = position
        if bytes[position] == .zero, let prefix = peek(1), let digits = Markers.radixDigits[prefix]
        {
            position += 2
            while let byte = peek(0), digits.contains(byte) || byte == .underscore {
                position += 1
            }
        } else {
            skipDecimalDigits()
            if peek(0) == .dot, let fraction = peek(1), fraction.isDigit {
                position += 1
                skipDecimalDigits()
            }
            if let exponent = peek(0), exponent == .lowerE || exponent == .upperE {
                if let sign = peek(1), sign.isDigit {
                    position += 1
                    skipDecimalDigits()
                } else if let sign = peek(1), sign == .plus || sign == .minus, let digit = peek(2),
                    digit.isDigit
                {
                    position += 2
                    skipDecimalDigits()
                }
            }
        }
        for suffix in [UInt8.lowerR, UInt8.lowerI] {
            if peek(0) == suffix, peek(1)?.isIdentifierByte != true {
                position += 1
            }
        }
        emit(.number, start..<position)
    }

    private mutating func skipDecimalDigits() {
        while let byte = peek(0), byte.isDigit || byte == .underscore {
            position += 1
        }
    }

    // MARK: Words

    /// An identifier run. In order: a hash label (`name:`) is a symbol; a
    /// word right after `.` is a method call and gets no color (`x.class`,
    /// `obj.end`), but `..` is a range and doesn't count; a reserved word is
    /// a keyword; an uppercase-initial word is a constant. Anything else is
    /// a plain identifier and gets nothing.
    private mutating func scanWord() {
        let start = position
        skipIdentifier()
        skipMethodNameSuffix()
        let end = position
        if peek(0) == .colon && peek(1) != .colon {
            position += 1
            emit(.symbol, start..<position)
            return
        }
        if start > 0 && bytes[start - 1] == .dot && !(start > 1 && bytes[start - 2] == .dot) {
            return
        }
        if Markers.keywords.contains(Array(bytes[start..<end])) {
            emit(.keyword, start..<end)
        } else if bytes[start].isUppercaseLetter {
            emit(.constant, start..<end)
        }
    }

    private mutating func skipIdentifier() {
        while let byte = peek(0), byte.isIdentifierByte {
            position += 1
        }
    }

    /// A trailing `?` or `!` on a method-ish name (`empty?`, `save!`,
    /// `defined?`), unless it's the first byte of `!=` or `?=`.
    private mutating func skipMethodNameSuffix() {
        if let byte = peek(0), byte == .question || byte == .bang, peek(1) != .equals {
            position += 1
        }
    }

    // MARK: Helpers

    private mutating func emit(_ kind: RubyToken.Kind, _ range: Range<Int>) {
        guard !range.isEmpty else { return }
        tokens.append(RubyToken(kind: kind, range: range))
    }

    private func at(_ index: Int) -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func peek(_ offset: Int) -> UInt8? {
        at(position + offset)
    }

    private func hasPrefix(_ marker: [UInt8]) -> Bool {
        position + marker.count <= bytes.count
            && bytes[position..<position + marker.count].elementsEqual(marker)
    }

    private func isBlank(at index: Int) -> Bool {
        guard let byte = at(index) else { return true }
        return byte == .space || byte == .tab || byte == .newline || byte == .carriageReturn
    }

    private func isLineEnd(at index: Int) -> Bool {
        guard let byte = at(index) else { return true }
        return byte == .newline || byte == .carriageReturn
    }

    /// The index of the next newline at or after `index`, or `bytes.count`.
    private func lineEnd(from index: Int) -> Int {
        var end = index
        while end < bytes.count && bytes[end] != .newline {
            end += 1
        }
        return end
    }
}

// MARK: - Byte tables

/// The multi-byte markers and byte sets the scanner matches against, as
/// UTF-8 bytes so no `String` comparisons happen on the keystroke path.
nonisolated private enum Markers {
    static let beginComment = Array("=begin".utf8)
    static let endComment = Array("=end".utf8)
    static let dataSection = Array("__END__".utf8)

    static let keywords: Set<[UInt8]> = Set(
        [
            "alias", "and", "begin", "BEGIN", "break", "case", "class", "def", "defined?", "do",
            "else", "elsif", "end", "END", "ensure", "false", "for", "if", "in", "module", "next",
            "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then",
            "true",
            "undef", "unless", "until", "when", "while", "yield", "__FILE__", "__LINE__",
            "__ENCODING__",
        ].map { Array($0.utf8) }
    )

    /// Words after which a `/` opens a regex rather than dividing.
    static let regexPrecedingWords: Set<[UInt8]> = Set(
        ["if", "unless", "while", "until", "when", "and", "or", "not", "return"].map {
            Array($0.utf8)
        }
    )

    /// Bytes after which a `/` opens a regex rather than dividing.
    static let regexPrecedingBytes = Set("(,=~!|&{[;".utf8)

    /// The letter after `%` that picks a literal type (`%w`, `%q`, …).
    static let percentLiteralTypes = Set("wWiIqQrsx".utf8)

    /// The subset of ``percentLiteralTypes`` whose bodies interpolate.
    static let interpolatingPercentTypes = Set("WIQrx".utf8)

    /// Delimiters accepted right after a bare `%` (`%(…)`, `%[…]`).
    static let barePercentDelimiters = Set("([{<|!/^".utf8)

    /// The one-character globals: `$!`, `$0` and friends (digits are handled
    /// separately since they can run on).
    static let specialGlobals = Set("!@&`'+~=/\\,;.<>*$?:\"".utf8)

    /// Digit sets keyed by the letter after a leading `0`.
    static let radixDigits: [UInt8: Set<UInt8>] = {
        let hex = Set("0123456789abcdefABCDEF".utf8)
        let binary = Set("01".utf8)
        let octal = Set("01234567".utf8)
        let decimal = Set("0123456789".utf8)
        return [
            UInt8(ascii: "x"): hex, UInt8(ascii: "X"): hex,
            UInt8(ascii: "b"): binary, UInt8(ascii: "B"): binary,
            UInt8(ascii: "o"): octal, UInt8(ascii: "O"): octal,
            UInt8(ascii: "d"): decimal, UInt8(ascii: "D"): decimal,
        ]
    }()
}

nonisolated extension UInt8 {
    fileprivate static let newline = UInt8(ascii: "\n")
    fileprivate static let carriageReturn = UInt8(ascii: "\r")
    fileprivate static let space = UInt8(ascii: " ")
    fileprivate static let tab = UInt8(ascii: "\t")
    fileprivate static let hash = UInt8(ascii: "#")
    fileprivate static let singleQuote = UInt8(ascii: "'")
    fileprivate static let doubleQuote = UInt8(ascii: "\"")
    fileprivate static let backtick = UInt8(ascii: "`")
    fileprivate static let backslash = UInt8(ascii: "\\")
    fileprivate static let percent = UInt8(ascii: "%")
    fileprivate static let slash = UInt8(ascii: "/")
    fileprivate static let lessThan = UInt8(ascii: "<")
    fileprivate static let greaterThan = UInt8(ascii: ">")
    fileprivate static let colon = UInt8(ascii: ":")
    fileprivate static let at = UInt8(ascii: "@")
    fileprivate static let dollar = UInt8(ascii: "$")
    fileprivate static let dot = UInt8(ascii: ".")
    fileprivate static let equals = UInt8(ascii: "=")
    fileprivate static let tilde = UInt8(ascii: "~")
    fileprivate static let minus = UInt8(ascii: "-")
    fileprivate static let plus = UInt8(ascii: "+")
    fileprivate static let question = UInt8(ascii: "?")
    fileprivate static let bang = UInt8(ascii: "!")
    fileprivate static let underscore = UInt8(ascii: "_")
    fileprivate static let zero = UInt8(ascii: "0")
    fileprivate static let lowerE = UInt8(ascii: "e")
    fileprivate static let upperE = UInt8(ascii: "E")
    fileprivate static let lowerR = UInt8(ascii: "r")
    fileprivate static let lowerI = UInt8(ascii: "i")
    fileprivate static let leftParen = UInt8(ascii: "(")
    fileprivate static let rightParen = UInt8(ascii: ")")
    fileprivate static let leftBracket = UInt8(ascii: "[")
    fileprivate static let rightBracket = UInt8(ascii: "]")
    fileprivate static let leftBrace = UInt8(ascii: "{")
    fileprivate static let rightBrace = UInt8(ascii: "}")

    fileprivate var isDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
    fileprivate var isUppercaseLetter: Bool {
        self >= UInt8(ascii: "A") && self <= UInt8(ascii: "Z")
    }
    fileprivate var isLowercaseLetter: Bool {
        self >= UInt8(ascii: "a") && self <= UInt8(ascii: "z")
    }

    /// Letters, `_`, and every non-ASCII byte, so non-ASCII names lex as
    /// identifiers instead of being split byte by byte.
    fileprivate var isIdentifierStart: Bool {
        isUppercaseLetter || isLowercaseLetter || self == .underscore || self >= 0x80
    }

    fileprivate var isIdentifierByte: Bool { isIdentifierStart || isDigit }

    /// Anything that can delimit a `%w`-style literal: printable ASCII that
    /// isn't a letter, digit, `_` or whitespace.
    fileprivate var isPercentDelimiter: Bool {
        self > 0x20 && self < 0x7F && !isIdentifierByte
    }

    /// The closing delimiter paired with this opener; the same byte for
    /// non-bracket delimiters (`%q|…|`).
    fileprivate var matchingCloser: UInt8 {
        switch self {
        case .leftParen: .rightParen
        case .leftBracket: .rightBracket
        case .leftBrace: .rightBrace
        case .lessThan: .greaterThan
        default: self
        }
    }
}
