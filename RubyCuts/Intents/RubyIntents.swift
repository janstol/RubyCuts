import AppIntents
import Foundation

/// Text-input options used at each text `@Parameter` below: multiline, with
/// autocorrect / smart quotes / smart dashes / auto-capitalization all off.
/// Shortcuts' defaults (smart quotes, sentence capitalization, autocorrect)
/// would silently mangle Ruby source or piped data -- e.g. turning `'hi'` into
/// `'hi'` with curly quotes, which is a syntax error in Ruby. Inlined at each
/// `@Parameter` (rather than shared via a `let`) because the App Intents
/// metadata extractor parses each `@Parameter`'s arguments at compile time and
/// requires a direct `String.IntentInputOptions` initializer call.

/// The error surfaced in Shortcuts when a "Run ..." Ruby intent fails. Conforms
/// to `CustomLocalizedStringResourceConvertible`, which is the protocol the App
/// Intents failure UI actually reads -- the PRD 3.1 contract that a failed run
/// reports *what Ruby said*, not "an error occurred" / the error's type name.
///
/// `CustomStringConvertible` alone turned out not to be enough: Shortcuts
/// rendered "The operation couldn't be completed. (RubyCuts.RubyRunError
/// error 1.)" -- the generic `NSError` fallback -- because the failure sheet
/// looks up `localizedStringResource`, not `description`. Keeping
/// `description` too, for non-Shortcuts contexts (logs, the test assertions,
/// `po` in the debugger) where `CustomStringConvertible` is what's printed.
///
/// `localizedStringResource` interpolates the runtime message rather than
/// passing it as a key: `LocalizedStringResource(message)` would be a
/// `LocalizationValue` literal (a *key to look up*), but a `String` variable
/// can't be one, so the string-interpolation form `"\(message)"` carries it
/// through as a `%@` substitution whose resolved value is the message text
/// itself -- no localization table involved.
struct RubyRunError: Error, CustomLocalizedStringResourceConvertible, CustomStringConvertible {
    /// The Ruby-side message: the exception `to_s` (when the script raised)
    /// and/or the captured `$stderr` text, joined so the failure shows
    /// everything that went wrong in one string.
    let message: String

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource("\(message)")
    }

    var description: String { message }
}

/// The PRD 3.1 output/error contract as a pure decision over a ``RunResult``:
/// a clean run (no exception, empty `$stderr`) returns its captured `$stdout`;
/// anything else (a raise *or* a populated `$stderr`) fails with a
/// ``RubyRunError`` combining the message and stderr.
///
/// Pure on purpose -- no VM, no I/O -- so the contract is unit-testable without
/// booting CRuby. ``runToOutput(_:)`` is the only side-effectful caller; this
/// function is the seam.
///
/// The rule "populated STDERR fails the run" matches the console's read of a
/// run and the PRD's "fails with the Ruby trace on crash/STDERR": a script that
/// only `warn`s or writes `$stderr` but doesn't raise still fails the intent,
/// because downstream Shortcut actions shouldn't consume a stream the script
/// itself flagged as an error.
func output(from result: RunResult) -> Result<String, RubyRunError> {
    if !result.stderr.isEmpty || result.hasError {
        return .failure(RubyRunError(message: combinedMessage(result)))
    }
    return .success(result.stdout)
}

/// Joins a ``RunResult``'s error message, backtrace, and stderr into a single
/// failure string, skipping whichever parts are empty so the output isn't
/// padded with blank lines. Order is error message first (the headline), then
/// the backtrace (the frames that raise came from), then stderr (the context
/// around it).
private func combinedMessage(_ result: RunResult) -> String {
    var parts: [String] = []
    if let message = result.errorMessage, !message.isEmpty {
        parts.append(message)
    }
    if !result.backtrace.isEmpty {
        parts.append(result.backtrace.joined(separator: "\n"))
    }
    if !result.stderr.isEmpty {
        parts.append(result.stderr)
    }
    return parts.joined(separator: "\n")
}

/// Runs `source` through the embedded VM and applies the PRD output/error
/// contract (see ``output(from:)``). Returns the captured `$stdout` for the
/// next Shortcut action to consume, or throws a ``RubyRunError`` describing the
/// failure.
///
/// `input` carries the ARGV/STDIN/ENV a Shortcut forwarded in; it defaults to
/// ``RunInput/empty`` so callers that don't pass input (the existing test paths)
/// stay on the no-input run. The pure ``output(from:)`` contract is unchanged,
/// so `IntentOutputTests` is unaffected -- this is the only side-effectful
/// caller.
///
/// `@MainActor` because ``RubyRuntime/shared`` is pinned to the main actor (the
/// VM is single-threaded); the App Intent `perform()` is `@MainActor` too, so
/// the call site is already there. The same long-script-blocks-UI caveat as the
/// console applies -- true backgrounding is the later threading redesign.
@MainActor
func runToOutput(_ source: String, input: RunInput = .empty) throws -> String {
    let result = RubyRuntime.shared.run(source, input: input)
    return try output(from: result).get()
}

/// "Run Inline Ruby": runs a multiline Ruby code string and returns its
/// `$stdout` to the next Shortcut action. Fails (throws ``RubyRunError``) when
/// the code raises or writes to `$stderr`, surfacing the Ruby message in the
/// Shortcuts failure UI.
///
/// The three input parameters are all optional with empty defaults, so a simple
/// `puts "hi"` isn't cluttered with required fields -- ARGV/STDIN/Environment
/// are filled only when the script reads input. ARGV is a Shortcuts List of
/// strings (each becomes one `ARGV` element); STDIN is a string piped from a
/// previous action (fed to `$stdin`); Environment is a `KEY=value`-per-line
/// text field parsed by ``parseEnv(_:)`` into `ENV` entries.
struct RunInlineRubyIntent: AppIntent {
    @Parameter(
        title: "ARGV",
        description: "One ARGV element per list entry. e.g. two entries make ARGV[0] and ARGV[1].",
        default: []
    )
    var argv: [String]

    @Parameter(
        title: "STDIN",
        description: "Text piped from the previous action. Read it in Ruby with $stdin.read.",
        default: "",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none,
            multiline: true,
            autocorrect: false,
            smartQuotes: false,
            smartDashes: false
        )
    )
    var stdin: String

    @Parameter(
        title: "Environment",
        description: "One KEY=value per line. Example: TOKEN=secret sets ENV[\"TOKEN\"].",
        default: "",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none,
            multiline: true,
            autocorrect: false,
            smartQuotes: false,
            smartDashes: false
        )
    )
    var env: String

    // Code is declared last so Shortcuts renders the input fields above it and
    // the (multiline) code editor below -- the script is the main payload, so it
    // gets the large field under the smaller inputs.
    @Parameter(
        title: "Code",
        description: "Ruby to run, e.g. puts ARGV[0] or puts $stdin.read.",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none,
            multiline: true,
            autocorrect: false,
            smartQuotes: false,
            smartDashes: false
        )
    )
    var code: String

    static let title: LocalizedStringResource = "Run Inline Ruby"

    static var description: IntentDescription? {
        IntentDescription("Runs Ruby code and returns its output to the next action.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let input = RunInput(argv: argv, stdin: stdin, env: parseEnv(env))
        return .result(value: try runToOutput(code, input: input))
    }
}

/// "Run Ruby Script": runs a script chosen from the stored scripts in
/// ``ScriptStore/userScripts`` and returns its `$stdout`. Fails (throws
/// ``RubyRunError``) when the script can't be read, raises, or writes to
/// `$stderr`.
///
/// The script is picked through ``ScriptEntity``'s picker, so the user selects
/// a saved script by name rather than typing a path. A stored Shortcut holds the
/// script's file-URL id; if that script has since been moved or deleted the
/// read throws and the intent fails with "script not found" -- acceptable for
/// V1 (noted in the PRD).
struct RunRubyScriptIntent: AppIntent {
    @Parameter(
        title: "Script",
        description: "A saved Ruby script from your library."
    )
    var script: ScriptEntity

    @Parameter(
        title: "ARGV",
        description: "One ARGV element per list entry. e.g. two entries make ARGV[0] and ARGV[1].",
        default: []
    )
    var argv: [String]

    @Parameter(
        title: "STDIN",
        description: "Text piped from the previous action. Read it in Ruby with $stdin.read.",
        default: "",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none,
            multiline: true,
            autocorrect: false,
            smartQuotes: false,
            smartDashes: false
        )
    )
    var stdin: String

    @Parameter(
        title: "Environment",
        description: "One KEY=value per line. Example: TOKEN=secret sets ENV[\"TOKEN\"].",
        default: "",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none,
            multiline: true,
            autocorrect: false,
            smartQuotes: false,
            smartDashes: false
        )
    )
    var env: String

    static let title: LocalizedStringResource = "Run Ruby Script"

    static var description: IntentDescription? {
        IntentDescription("Runs a saved Ruby script and returns its output to the next action.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let resolved = script.script else {
            throw RubyRunError(message: "script not found")
        }
        let source = try ScriptStore.userScripts.source(of: resolved)
        let input = RunInput(argv: argv, stdin: stdin, env: parseEnv(env))
        return .result(value: try runToOutput(source, input: input))
    }
}
