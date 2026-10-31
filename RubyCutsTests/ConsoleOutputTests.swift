import Foundation
@testable import RubyCuts
import Testing

/// Pure-value tests for ``ConsoleOutputView``'s static helpers: no VM, no
/// rendered view. `transcript(for:)` mirrors the view's own section order and
/// suppression rules; `durationLabel(for:)` is hand-rolled formatting with no
/// locale dependence to worry about.
@MainActor
struct ConsoleOutputTests {

    // MARK: - transcript(for:)

    @Test func transcriptIncludesEveryPopulatedSectionInViewOrder() throws {
        let result = RunResult(
            stdout: "hi\n",
            stderr: "warn\n",
            result: "42",
            errorMessage: "boom",
            backtrace: ["rubycuts:1:in '<main>'"]
        )
        let transcript = ConsoleOutputView.transcript(for: result)

        let outputRange = try #require(transcript.range(of: "Output:"))
        let errorsRange = try #require(transcript.range(of: "Errors:"))
        let errorRange = try #require(transcript.range(of: "Error:"))
        let backtraceRange = try #require(transcript.range(of: "Backtrace:"))

        #expect(outputRange.lowerBound < errorsRange.lowerBound)
        #expect(errorsRange.lowerBound < errorRange.lowerBound)
        #expect(errorRange.lowerBound < backtraceRange.lowerBound)
        // A failed run has no meaningful `result`, so no Result section here.
        #expect(!transcript.contains("Result:"))

        #expect(transcript.contains("hi"))
        #expect(transcript.contains("warn"))
        #expect(transcript.contains("boom"))
        #expect(transcript.contains("rubycuts:1:in '<main>'"))
    }

    @Test func transcriptSkipsEmptySectionsWithNoBlankLinePadding() {
        let result = RunResult(stdout: "hi\n", stderr: "", result: "", errorMessage: nil)
        let transcript = ConsoleOutputView.transcript(for: result)

        #expect(transcript == "Output:\nhi\n")
    }

    @Test func transcriptOfACleanPutsOnlyRunIsJustTheOutputSection() {
        let result = RunResult(stdout: "hello\n", stderr: "", result: "", errorMessage: nil)
        let transcript = ConsoleOutputView.transcript(for: result)

        #expect(transcript == "Output:\nhello\n")
    }

    @Test func transcriptOfACancelledRunOmitsTheErrorSection() {
        // Matches the view's own suppression rule: "run cancelled" as a red
        // error reads like a bug rather than the user's own action.
        let result = RunResult(
            stdout: "before\n", stderr: "", result: "",
            errorMessage: "run cancelled", wasCancelled: true
        )
        let transcript = ConsoleOutputView.transcript(for: result)

        #expect(!transcript.contains("Error:"))
        #expect(transcript.contains("before"))
    }

    // MARK: - durationLabel(for:)

    @Test func durationLabelFormatsSubMinuteAsSeconds() {
        #expect(ConsoleOutputView.durationLabel(for: 0.42) == "0.42s")
    }

    @Test func durationLabelFormatsOverAMinuteAsMinutesAndSeconds() {
        #expect(ConsoleOutputView.durationLabel(for: 65) == "1m 5s")
    }

    // MARK: - metadataAccessibilityLabel(for:)

    @Test func metadataAccessibilityLabelSpellsOutTheDurationInsteadOfAbbreviating() {
        let result = RunResult(
            stdout: "", stderr: "", result: "", errorMessage: nil, duration: 0.03,
            finishedAt: Date(timeIntervalSince1970: 0)
        )

        let label = ConsoleOutputView.metadataAccessibilityLabel(for: result)

        #expect(label.contains("0.03 seconds"))
        // Neither the abbreviated "0.03s" nor the raw middle dot from the
        // visual label should leak into the spoken form.
        #expect(!label.contains("0.03s"))
        #expect(!label.contains("·"))
    }

    @Test func metadataAccessibilityLabelSpellsOutMinutesAndSecondsOverAMinute() {
        let result = RunResult(
            stdout: "", stderr: "", result: "", errorMessage: nil, duration: 65,
            finishedAt: Date(timeIntervalSince1970: 0)
        )

        let label = ConsoleOutputView.metadataAccessibilityLabel(for: result)

        #expect(label.contains("1 minute 5 seconds"))
    }

    @Test func truncatedStreamsCarryANoteInTheTranscript() {
        var result = RunResult(stdout: "out", stderr: "err\n", result: "", errorMessage: nil)
        result.stdoutTruncated = true
        result.stderrTruncated = true

        let transcript = ConsoleOutputView.transcript(for: result)

        #expect(transcript.contains("Output:\nout\n[Cut off here:"))
        #expect(transcript.contains("Errors:\nerr\n[Cut off here:"))
    }

    @Test func anUntruncatedStreamIsShownUnchanged() {
        #expect(ConsoleOutputView.text("out", truncated: false) == "out")
    }

    // MARK: - What the console draws for large output

    @Test func outputThatFitsIsDrawnUnchanged() {
        let text = "one\ntwo\n"
        #expect(ConsoleOutputView.displayed(text) == text)
    }

    @Test func manyLinesAreDrawnAsTheTailWithANote() {
        let lines = (1...1_000).map { "line \($0)" }
        let drawn = ConsoleOutputView.displayed(lines.joined(separator: "\n"))
        let drawnLines = drawn.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(drawnLines.first == "[Showing the last 300 lines. Copy All copies everything.]")
        #expect(drawnLines.count == ConsoleOutputView.maxDisplayedLines + 1)
        #expect(drawnLines[1] == "line 701")
        #expect(drawnLines.last == "line 1000")
    }

    @Test func aVeryLongLineIsShortened() {
        let drawn = ConsoleOutputView.displayed(String(repeating: "x", count: 2_000_000))
        let drawnLines = drawn.split(separator: "\n")

        #expect(drawnLines.first == "[Long lines are shortened. Copy All copies everything.]")
        #expect(drawnLines.last?.count == ConsoleOutputView.maxDisplayedLineLength + 1)
        #expect(drawnLines.last?.hasSuffix("…") == true)
    }

    @Test func theCutOffNoteSurvivesBecauseItIsTheLastLine() {
        let captured = String(repeating: "x\n", count: 5_000)
        let drawn = ConsoleOutputView.displayed(ConsoleOutputView.text(captured, truncated: true))

        #expect(drawn.hasSuffix("[Cut off here: the output is larger than 1 MB.]"))
    }
}
