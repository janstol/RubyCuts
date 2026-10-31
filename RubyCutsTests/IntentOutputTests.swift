@testable import RubyCuts
import Testing

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

        let output = try Self.output(from: result).get()

        #expect(output == "hello\n")
    }

    @Test func cleanRunReturnsStdoutEvenWhenResultIsNonEmpty() throws {
        // The contract returns `$stdout`, not the last expression's `to_s`:
        // a script like `puts 'hi'; 42` prints `hi\n` and evaluates to `42`,
        // and Shortcuts should get `hi\n`, not `42`.
        let result = RunResult(stdout: "hi\n", stderr: "", result: "42", errorMessage: nil)

        let output = try Self.output(from: result).get()

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

    @Test func crashWithBacktraceIncludesTheTraceInTheMessage() throws {
        let result = RunResult(
            stdout: "", stderr: "", result: "", errorMessage: "boom",
            backtrace: ["eval:2:in 'Object#foo'", "eval:4:in '<main>'"]
        )

        let error = try #require(throws: RubyRunError.self) {
            try Self.output(from: result).get()
        }

        #expect(error.message == "boom\neval:2:in 'Object#foo'\neval:4:in '<main>'")
    }

    @Test func backtraceIsOrderedBetweenMessageAndStderr() throws {
        // Order is message, then backtrace, then stderr: the trace belongs
        // directly under the raise it describes.
        let result = RunResult(
            stdout: "", stderr: "warn\n", result: "", errorMessage: "boom",
            backtrace: ["eval:1:in '<main>'"]
        )

        let error = try #require(throws: RubyRunError.self) {
            try Self.output(from: result).get()
        }

        #expect(error.message == "boom\neval:1:in '<main>'\nwarn\n")
    }

    @Test func emptyCrashAndEmptyStderrSucceedsWithEmptyStdout() throws {
        // A boot failure surfaces as a `RunResult` with `errorMessage` set, so
        // it fails, but a genuinely empty result (no error, no stderr) is a
        // clean run whose stdout happens to be empty (e.g. `42` with no `puts`).
        let result = RunResult(stdout: "", stderr: "", result: "42", errorMessage: nil)

        let output = try Self.output(from: result).get()

        #expect(output.isEmpty)
    }

    /// Thin wrapper so tests read `Self.output(from:)` and the call site makes
    /// the seam explicit, rather than naming the free function in every test.
    private static func output(from result: RunResult) -> Result<String, RubyRunError> {
        RubyCuts.output(from: result)
    }

    // MARK: - parseEnv(_:): the "Environment" text field -> ENV pairs
    //
    // Labeled 2-tuples don't conform to `Equatable`, so arrays of
    // `(key:value:)` pairs can't use `==` directly. ``kv(_:)`` renders each
    // pair as a `k=v` string (which *is* `Equatable`), giving concise assertions
    // that still produce a readable diff on failure.

    @Test func parseEnvParsesOneKeyEqualValue() {
        // The basic `KEY=value` shape: one line, one pair.
        let pairs = parseEnv("KEY=value")
        #expect(Self.kv(pairs) == ["KEY=value"])
    }

    @Test func parseEnvKeepsEqualsInValue() {
        // Only the first `=` splits, so a value may itself contain `=`
        // (base64 strings, connection URLs, ...).
        let pairs = parseEnv("TOKEN=abc=def")
        #expect(Self.kv(pairs) == ["TOKEN=abc=def"])
    }

    @Test func parseEnvParsesMultipleLines() {
        // Each non-blank line is one pair, in order.
        let pairs = parseEnv("A=1\nB=2\nC=3")
        #expect(Self.kv(pairs) == ["A=1", "B=2", "C=3"])
    }

    @Test func parseEnvSkipsBlankAndInvalidLines() {
        // Blank lines and lines with no `=` (no key) are skipped without a
        // pair; valid lines around them are still parsed in order.
        let pairs = parseEnv("A=1\n\nnot-a-pair\nB=2")
        #expect(Self.kv(pairs) == ["A=1", "B=2"])
    }

    @Test func parseEnvSkipsEmptyKey() {
        // A line `=value` has no real key, so it's skipped too: setting
        // `ENV[""]` in Ruby would be a meaningless error otherwise.
        let pairs = parseEnv("=value\nKEY=ok")
        #expect(Self.kv(pairs) == ["KEY=ok"])
    }

    @Test func parseEnvPreservesWhitespace() {
        // Nothing is trimmed: ` KEY` (with a leading space) is a different key
        // from `KEY`, and trimming would silently change what the script sees.
        let pairs = parseEnv(" KEY = value with spaces ")
        #expect(Self.kv(pairs) == [" KEY = value with spaces "])
    }

    @Test func parseEnvReturnsEmptyForEmptyText() {
        #expect(parseEnv("").isEmpty)
    }

    /// Renders `(key, value)` pairs as `k=v` strings for `==` comparison (see
    /// the section header above).
    private static func kv(_ pairs: [(key: String, value: String)]) -> [String] {
        pairs.map { "\($0.key)=\($0.value)" }
    }
}
