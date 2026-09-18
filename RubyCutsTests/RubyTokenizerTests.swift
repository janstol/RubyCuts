@testable import RubyCuts
import Testing

// A pure function over a `String`, no I/O, no `.serialized` needed, unlike
// the VM-driving suites. Runs concurrently with everything else.
struct RubyTokenizerTests {

    /// Each token as its kind plus the exact source text it covers, sliced
    /// by the token's UTF-8 byte range, so a wrong range shows up as wrong
    /// text rather than as an opaque pair of integers.
    private func kinds(of source: String) -> [(RubyToken.Kind, String)] {
        let bytes = Array(source.utf8)
        return RubyTokenizer.tokenize(source).map { token in
            (token.kind, String(decoding: bytes[token.range], as: UTF8.self))
        }
    }

    private func expectTokens(
        _ source: String,
        _ expected: [(RubyToken.Kind, String)],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let actual = kinds(of: source)
        #expect(
            actual.count == expected.count,
            "\(actual) vs \(expected)",
            sourceLocation: sourceLocation
        )
        for (got, want) in zip(actual, expected) {
            #expect(got.0 == want.0, "\(actual)", sourceLocation: sourceLocation)
            #expect(got.1 == want.1, "\(actual)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Basics

    @Test func emptyInputYieldsNothing() {
        #expect(RubyTokenizer.tokenize("").isEmpty)
    }

    @Test func plainIdentifiersAndOperatorsYieldNothing() {
        #expect(RubyTokenizer.tokenize("foo = bar + baz(qux)").isEmpty)
        #expect(RubyTokenizer.tokenize("puts x").isEmpty)
    }

    // MARK: - Comments

    @Test func hashCommentRunsToEndOfLine() {
        expectTokens("x = 1 # note\ny", [(.number, "1"), (.comment, "# note")])
    }

    @Test func hashInsideStringIsNotAComment() {
        expectTokens("\"a # b\"", [(.string, "\"a # b\"")])
    }

    @Test func beginEndBlockIsOneComment() {
        let source = "x\n=begin\nsome\ntext\n=end\ny"
        expectTokens(source, [(.comment, "=begin\nsome\ntext\n=end")])
    }

    @Test func beginNotAtLineStartIsNotAComment() {
        // Mid-line, `=begin` is just `=` followed by the `begin` keyword.
        expectTokens("x =begin", [(.keyword, "begin")])
    }

    @Test func dataSectionAfterEndMarkerIsAComment() {
        let source = "puts 1\n__END__\ndef x\n\"y\""
        expectTokens(source, [(.number, "1"), (.comment, "__END__\ndef x\n\"y\"")])
    }

    // MARK: - Strings

    @Test func singleQuotedStringWithEscapedQuote() {
        expectTokens("'it\\'s' + x", [(.string, "'it\\'s'")])
    }

    @Test func doubleQuotedStringWithEscapesAndInterpolation() {
        expectTokens(
            "\"a\\\"b #{h[\"k\"]} c\" ; d",
            [(.string, "\"a\\\"b #{h[\"k\"]} c\"")]
        )
    }

    @Test func backtickStringIsAString() {
        expectTokens("`ls #{dir}`", [(.string, "`ls #{dir}`")])
    }

    @Test func percentWordArray() {
        expectTokens("%w[a b] + x", [(.string, "%w[a b]")])
    }

    @Test func percentLiteralsNest() {
        expectTokens("%q(( )) x", [(.string, "%q(( ))")])
        expectTokens("%Q{a #{b} c}", [(.string, "%Q{a #{b} c}")])
    }

    @Test func percentAsModuloIsSkipped() {
        expectTokens("a % b", [])
        expectTokens("10 %3", [(.number, "10"), (.number, "3")])
        expectTokens("x%w[1]", [(.number, "1")])
    }

    @Test func unterminatedStringRunsToEndOfInput() {
        expectTokens("x = \"abc\ndef y", [(.string, "\"abc\ndef y")])
    }

    // MARK: - Heredocs

    @Test func heredocBodyIsOneStringTokenAndOpenerLineStillLexes() {
        let source = "x = <<~TEXT.strip # c\n  hi #{name}\n  TEXT\nputs :done"
        expectTokens(
            source,
            [
                (.string, "<<~TEXT"),
                (.comment, "# c"),
                (.string, "  hi #{name}\n  TEXT"),
                (.symbol, ":done"),
            ]
        )
    }

    @Test func quotedHeredocTerminatorAndUnindentedForm() {
        let source = "a = <<-'EOS'\n  raw\n  EOS\nb = <<EOS\nx\nEOS\n1"
        expectTokens(
            source,
            [
                (.string, "<<-'EOS'"),
                (.string, "  raw\n  EOS"),
                (.string, "<<EOS"),
                (.string, "x\nEOS"),
                (.number, "1"),
            ]
        )
    }

    @Test func unterminatedHeredocRunsToEndOfInput() {
        expectTokens("<<~T\nbody\nmore", [(.string, "<<~T"), (.string, "body\nmore")])
    }

    @Test func shiftAppendIsNotAHeredoc() {
        expectTokens("list << item", [])
        expectTokens("class << self", [(.keyword, "class"), (.keyword, "self")])
    }

    // MARK: - Regex vs division

    @Test func regexAfterAssignmentParenAndKeyword() {
        expectTokens("x = /a\\/b/i", [(.string, "/a\\/b/i")])
        expectTokens("f(/x/, 1)", [(.string, "/x/"), (.number, "1")])
        expectTokens("y if /z/", [(.keyword, "if"), (.string, "/z/")])
        expectTokens("/^a/\n", [(.string, "/^a/")])
    }

    @Test func divisionIsSkipped() {
        expectTokens("a / b", [])
        expectTokens("x /2", [(.number, "2")])
        expectTokens("f(1) / 2", [(.number, "1"), (.number, "2")])
    }

    // MARK: - Symbols

    @Test func symbolsAndLabels() {
        expectTokens(":foo", [(.symbol, ":foo")])
        expectTokens(":foo?", [(.symbol, ":foo?")])
        expectTokens(":name=", [(.symbol, ":name=")])
        expectTokens(":\"a b\"", [(.symbol, ":\"a b\"")])
        expectTokens("key: 1", [(.symbol, "key:"), (.number, "1")])
    }

    @Test func scopeResolutionYieldsConstantsNotSymbols() {
        expectTokens("Foo::Bar", [(.constant, "Foo"), (.constant, "Bar")])
    }

    @Test func ternaryColonYieldsNoSymbol() {
        expectTokens("a ? b : c", [])
    }

    @Test func hashRocketDoesNotAbsorbEquals() {
        expectTokens("{:a=>1}", [(.symbol, ":a"), (.number, "1")])
    }

    // MARK: - Numbers

    @Test func numberForms() {
        expectTokens("42", [(.number, "42")])
        expectTokens("1_000", [(.number, "1_000")])
        expectTokens("3.14", [(.number, "3.14")])
        expectTokens("1e5", [(.number, "1e5")])
        expectTokens("2.5e-3", [(.number, "2.5e-3")])
        expectTokens("0xff", [(.number, "0xff")])
        expectTokens("0b1010", [(.number, "0b1010")])
        expectTokens("2r", [(.number, "2r")])
    }

    @Test func digitsInsideIdentifiersAreNotNumbers() {
        #expect(RubyTokenizer.tokenize("abc123").isEmpty)
    }

    @Test func methodCallOnNumberKeepsTheNumberShort() {
        expectTokens("3.times", [(.number, "3")])
        expectTokens("1..5", [(.number, "1"), (.number, "5")])
    }

    // MARK: - Keywords

    @Test func reservedWordsAreKeywords() {
        expectTokens(
            "def x; end if y",
            [(.keyword, "def"), (.keyword, "end"), (.keyword, "if")]
        )
        expectTokens("defined?(x)", [(.keyword, "defined?")])
    }

    @Test func methodCallsNamedLikeKeywordsAreNot() {
        expectTokens("x.class", [])
        expectTokens("obj.end", [])
        expectTokens("x&.class", [])
    }

    @Test func keywordLabelIsASymbol() {
        expectTokens("class: 1", [(.symbol, "class:"), (.number, "1")])
    }

    @Test func rangeToConstantIsNotAMethodCall() {
        expectTokens("1..MAX", [(.number, "1"), (.constant, "MAX")])
    }

    @Test func methodNamesLikePutsAndRequireAreNotKeywords() {
        #expect(RubyTokenizer.tokenize("require x\nputs y\nattr_accessor").isEmpty)
    }

    // MARK: - Constants and variables

    @Test func constants() {
        expectTokens("JSON.parse", [(.constant, "JSON")])
        expectTokens("Net::HTTP", [(.constant, "Net"), (.constant, "HTTP")])
    }

    @Test func variables() {
        expectTokens("@a", [(.variable, "@a")])
        expectTokens("@@b", [(.variable, "@@b")])
        expectTokens("$stdout", [(.variable, "$stdout")])
        expectTokens("$0", [(.variable, "$0")])
        expectTokens("$!", [(.variable, "$!")])
        expectTokens("@a.b", [(.variable, "@a")])
    }

    // MARK: - Non-ASCII

    @Test func nonASCIIBytesKeepRangesAligned() {
        expectTokens(
            "puts \"žluť\" # č\nx = :ď",
            [(.string, "\"žluť\""), (.comment, "# č"), (.symbol, ":ď")]
        )
    }

    // MARK: - Invariants

    @Test func sampleScriptTokensAreSortedAndDisjoint() {
        for sample in SampleScripts.all {
            let tokens = RubyTokenizer.tokenize(sample.source)
            let byteCount = sample.source.utf8.count
            #expect(!tokens.isEmpty, "\(sample.name)")
            var previousEnd = 0
            for token in tokens {
                #expect(!token.range.isEmpty, "\(sample.name)")
                #expect(token.range.lowerBound >= previousEnd, "\(sample.name): \(token)")
                #expect(token.range.upperBound <= byteCount, "\(sample.name)")
                previousEnd = token.range.upperBound
            }
        }
    }
}
