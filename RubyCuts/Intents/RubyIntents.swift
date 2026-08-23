import AppIntents
import Foundation

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

/// Joins a ``RunResult``'s error message and stderr into a single failure
/// string, skipping whichever half is empty so the output isn't padded with a
/// blank line. Order is error-first (the raise is usually the headline), stderr
/// second (the context around it).
private func combinedMessage(_ result: RunResult) -> String {
    var parts: [String] = []
    if let message = result.errorMessage, !message.isEmpty {
        parts.append(message)
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
/// `@MainActor` because ``RubyRuntime/shared`` is pinned to the main actor (the
/// VM is single-threaded); the App Intent `perform()` is `@MainActor` too, so
/// the call site is already there. The same long-script-blocks-UI caveat as the
/// console applies -- true backgrounding is the later threading redesign.
@MainActor
func runToOutput(_ source: String) throws -> String {
    let result = RubyRuntime.shared.run(source)
    return try output(from: result).get()
}

/// "Run Inline Ruby": runs a multiline Ruby code string and returns its
/// `$stdout` to the next Shortcut action. Fails (throws ``RubyRunError``) when
/// the code raises or writes to `$stderr`, surfacing the Ruby message in the
/// Shortcuts failure UI.
///
/// This is the whole-product point of PRD 3.1 -- composing Ruby from Shortcuts
/// -- without the ARGV/STDIN/ENV input half (deferred to the Phase 4 input
/// slice; this is the output side only).
struct RunInlineRubyIntent: AppIntent {
    @Parameter(title: "Code")
    var code: String

    static let title: LocalizedStringResource = "Run Inline Ruby"

    static var description: IntentDescription? {
        IntentDescription("Runs Ruby code and returns its output to the next action.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try runToOutput(code))
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
    @Parameter(title: "Script")
    var script: ScriptEntity

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
        return .result(value: try runToOutput(source))
    }
}
