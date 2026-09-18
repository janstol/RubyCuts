@testable import RubyCuts
import SwiftUI
import Testing

// `RubySyntaxHighlighting` is main-actor isolated by the app target's
// default, hence the suite-level annotation. Pure otherwise: no I/O, no VM.
@MainActor
struct RubySyntaxHighlightingTests {

    /// The text's runs as (characters, color) pairs, so assertions read as
    /// the editor would render them.
    private func runs(of text: AttributedString) -> [(String, Color?)] {
        text.runs.map { run in
            (String(text[run.range].characters), run.foregroundColor)
        }
    }

    @Test func highlightedColorsKeywordAndLeavesIdentifierPlain() {
        let text = RubySyntaxHighlighting.highlighted("def x")
        let actual = runs(of: text)
        #expect(actual.count == 2)
        #expect(actual[0].0 == "def")
        #expect(actual[0].1 == RubySyntaxHighlighting.color(for: .keyword))
        #expect(actual[1].0 == " x")
        #expect(actual[1].1 == nil)
    }

    @Test func applyAfterEditRecolorsShiftedRangesWithoutStaleColor() {
        var text = RubySyntaxHighlighting.highlighted("def x")
        // Prepend so every existing range shifts, then append a comment.
        text.characters.insert(contentsOf: "y = 1; ", at: text.startIndex)
        text.characters.append(contentsOf: " # c")
        RubySyntaxHighlighting.apply(to: &text)

        let actual = runs(of: text)
        let expected: [(String, Color?)] = [
            ("y = ", nil),
            ("1", RubySyntaxHighlighting.color(for: .number)),
            ("; ", nil),
            ("def", RubySyntaxHighlighting.color(for: .keyword)),
            (" x ", nil),
            ("# c", .secondary),
        ]
        #expect(actual.count == expected.count, "\(actual)")
        for (got, want) in zip(actual, expected) {
            #expect(got.0 == want.0)
            #expect(got.1 == want.1)
        }
    }

    @Test func applyIsIdempotent() {
        var text = RubySyntaxHighlighting.highlighted("x = \"a\" # b\n@c = :d")
        let before = text
        RubySyntaxHighlighting.apply(to: &text)
        #expect(text == before)
    }

    @Test func applyStripsForeignAttributes() {
        var text = AttributedString("puts 1")
        text.font = .largeTitle
        text.inlinePresentationIntent = .stronglyEmphasized
        RubySyntaxHighlighting.apply(to: &text)
        for run in text.runs {
            #expect(run.font == nil)
            #expect(run.inlinePresentationIntent == nil)
        }
        #expect(String(text.characters) == "puts 1")
    }

    @Test func highlightedPreservesNonASCIICharacters() {
        let source = "puts \"žluťoučký kůň\" # č"
        let text = RubySyntaxHighlighting.highlighted(source)
        #expect(String(text.characters) == source)
        let actual = runs(of: text)
        #expect(actual.map(\.0) == ["puts ", "\"žluťoučký kůň\"", " ", "# č"])
    }
}
