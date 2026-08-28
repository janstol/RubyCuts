import Foundation
import Testing

@testable import RubyCuts

/// Pure-value tests for ``ConsoleOutputView``'s static helpers -- no VM, no
/// rendered view. `transcript(for:)` mirrors the view's own section order and
/// suppression rules; `durationLabel(for:)` is hand-rolled formatting with no
/// locale dependence to worry about.
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
}
