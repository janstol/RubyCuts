import Testing

@testable import RubyCuts

// Pure tests of the PRD 3.1 output/error contract (``output(from:)``): the
// decision a "Run ..." Ruby intent makes over a captured ``RunResult``, with no
// VM booted and no I/O. This is the unit-testable seam split out of
// ``runToOutput(_:)``; the VM-driving half lives in `RubyRuntimeTests` (one
// serialized suite for the single non-thread-safe interpreter).
//
// Not `@MainActor` and not `.serialized`: `output(from:)` is a pure
// nonisolated function over a `Sendable` value, so these run concurrently with
// everything else and touch no shared state.
struct IntentOutputTests {

    @Test func cleanRunReturnsStdout() throws {
        let result = RunResult(stdout: "hello\n", stderr: "", result: "nil", errorMessage: nil)

        let output = try #require(try Self.output(from: result).get())

        #expect(output == "hello\n")
    }

    @Test func cleanRunReturnsStdoutEvenWhenResultIsNonEmpty() throws {
        // The contract returns `$stdout`, not the last expression's `to_s` --
        // a script like `puts 'hi'; 42` prints `hi\n` and evaluates to `42`,
        // and Shortcuts should get `hi\n`, not `42`.
        let result = RunResult(stdout: "hi\n", stderr: "", result: "42", errorMessage: nil)

        let output = try #require(try Self.output(from: result).get())

        #expect(output == "hi\n")
    }

    @Test func crashThrowsWithTheRubyMessage() throws {
        let result = RunResult(stdout: "before\n", stderr: "", result: "", errorMessage: "boom")

        let error = try #require(throws: RubyRunError.self) {
            try Self.output(from: result).get()
        }

        #expect(error.message == "boom")
    }

    @Test func stderrOnlyThrowsEvenWithoutACrash() throws {
        // A script that `warn`s but doesn't raise still fails the intent: the
        // PRD says populated STDERR fails the run, so a downstream action
        // never consumes a stream the script itself flagged as an error.
        let result = RunResult(stdout: "", stderr: "warning\n", result: "nil", errorMessage: nil)

        let error = try #require(throws: RubyRunError.self) {
            try Self.output(from: result).get()
        }

        #expect(error.message == "warning\n")
    }

    @Test func crashAndStderrCombineBothInTheMessage() throws {
        // When a raise also printed to `$stderr` first, the failure carries
        // both: the exception message as the headline, the stderr as context.
        let result = RunResult(stdout: "out\n", stderr: "warn\n", result: "", errorMessage: "boom")

        let error = try #require(throws: RubyRunError.self) {
            try Self.output(from: result).get()
        }

        #expect(error.message == "boom\nwarn\n")
    }

    @Test func emptyCrashAndEmptyStderrSucceedsWithEmptyStdout() throws {
        // A boot failure surfaces as a `RunResult` with `errorMessage` set, so
        // it fails -- but a genuinely empty result (no error, no stderr) is a
        // clean run whose stdout happens to be empty (e.g. `42` with no `puts`).
        let result = RunResult(stdout: "", stderr: "", result: "42", errorMessage: nil)

        let output = try #require(try Self.output(from: result).get())

        #expect(output.isEmpty)
    }

    /// Thin wrapper so tests read `Self.output(from:)` and the call site makes
    /// the seam explicit, rather than naming the free function in every test.
    private static func output(from result: RunResult) -> Result<String, RubyRunError> {
        RubyCuts.output(from: result)
    }
}
