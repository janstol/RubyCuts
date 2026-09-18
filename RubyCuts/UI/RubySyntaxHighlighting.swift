import SwiftUI

/// Colors Ruby source for the script editor's `TextEditor` by turning
/// ``RubyTokenizer`` tokens into `foregroundColor` attributes on an
/// `AttributedString`. Attribute-only: the characters are never touched, so
/// the editor's selection and undo state survive a re-highlight.
///
/// Uses system colors so light/dark and Increase Contrast adapt for free,
/// and no font attribute at all: the editor's `.font` modifier remains the
/// default for every unattributed run, and ``apply(to:)`` clears every
/// attribute first, which also flattens pasted rich text (fonts, bold) back
/// to plain monospaced source.
enum RubySyntaxHighlighting {
    /// The palette, one place to tweak.
    static func color(for kind: RubyToken.Kind) -> Color {
        switch kind {
        case .comment: .secondary
        case .keyword: .purple
        case .string: .red
        case .symbol: .teal
        case .number: .blue
        case .constant: .indigo
        case .variable: .green
        }
    }

    /// Rebuilds the coloring of `text` from scratch: clears every attribute,
    /// then sets `foregroundColor` on each token's range. Running it again
    /// on already-highlighted text yields an equal value, which is what lets
    /// the editor's `onChange` loop terminate.
    static func apply(to text: inout AttributedString) {
        text.setAttributes(AttributeContainer())
        let tokens = RubyTokenizer.tokenize(String(text.characters))

        // Tokens carry UTF-8 offsets and arrive sorted, so one forward walk
        // over the `utf8` view maps them all onto `AttributedString` indices.
        // Ranges are resolved first and applied after: attribute changes
        // don't move characters, but keeping the two phases apart means no
        // index computed from the view is ever used across a mutation.
        let utf8 = text.utf8
        var cursor = utf8.startIndex
        var offset = 0
        var colored: [(Range<AttributedString.Index>, Color)] = []
        colored.reserveCapacity(tokens.count)
        for token in tokens {
            let lower = utf8.index(cursor, offsetBy: token.range.lowerBound - offset)
            let upper = utf8.index(lower, offsetBy: token.range.count)
            colored.append((lower..<upper, color(for: token.kind)))
            cursor = upper
            offset = token.range.upperBound
        }
        for (range, color) in colored {
            text[range].foregroundColor = color
        }
    }

    /// `AttributedString(source)` with ``apply(to:)`` run once; what the
    /// editor loads a script into.
    static func highlighted(_ source: String) -> AttributedString {
        var text = AttributedString(source)
        apply(to: &text)
        return text
    }
}
