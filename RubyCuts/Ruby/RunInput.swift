import Foundation

/// The parsed inputs a "Run ..." Ruby intent forwards into the script: ARGV,
/// STDIN, and ENV. A pure value type carrying exactly what the Shortcuts user
/// filled in, with no Ruby knowledge -- ``RubyRuntime/run(_:input:)`` is what
/// turns a non-empty ``RunInput`` into the base64 transport that injects these
/// into the VM before the user's code runs.
///
/// Opted out of the app target's MainActor-by-default isolation (see
/// `SWIFT_DEFAULT_ACTOR_ISOLATION` in `project.pbxproj`), matching ``Script``
/// and ``ScriptStore``: this is a pure value type with no actor-coupled state,
/// so every member is `nonisolated` and the type is usable from any context --
/// including the nonisolated test target, where ``parseEnv(_:)`` and the
/// ``empty``/``isEmpty`` surface are exercised without a main-actor hop.
struct RunInput: Sendable {
    /// The script's ARGV: each entry becomes one `ARGV` element. Empty means the
    /// ARGV channel wasn't filled, so ``RubyRuntime`` skips its setup/teardown.
    nonisolated var argv: [String]

    /// The script's STDIN: fed to `$stdin` as a string. Empty means the STDIN
    /// channel wasn't filled.
    nonisolated var stdin: String

    /// The script's ENV: each pair becomes one `ENV` entry. Empty means the ENV
    /// channel wasn't filled.
    nonisolated var env: [(key: String, value: String)]

    /// A run with no input on any channel. The default for
    /// ``RubyRuntime/run(_:input:)``, so the in-app console and every caller
    /// that doesn't pass input stays on today's exact path -- zero setup/teardown
    /// overhead, the base64 transport never runs.
    nonisolated static let empty = RunInput(argv: [], stdin: "", env: [])

    /// `true` when no channel carries input. Drives the opt-in path in
    /// ``RubyRuntime/run(_:input:)``: an empty input runs the plain capture
    /// path verbatim, a non-empty input runs the ARGV/STDIN/ENV setup/teardown.
    nonisolated var isEmpty: Bool { argv.isEmpty && stdin.isEmpty && env.isEmpty }

    /// Memberwise init, spelled `nonisolated` so callers off the main actor (the
    /// nonisolated test target) can build a ``RunInput`` without a hop.
    nonisolated init(
        argv: [String] = [],
        stdin: String = "",
        env: [(key: String, value: String)] = []
    ) {
        self.argv = argv
        self.stdin = stdin
        self.env = env
    }
}

/// Parses the Shortcuts "Environment" text field (one `KEY=value` per line) into
/// the `(key, value)` pairs ``RunInput/env`` holds.
///
/// Splitting rules, kept deliberately strict so a script author sees exactly
/// what they typed:
/// - Splits on newlines; each line is one potential pair.
/// - Splits each line on the *first* `=` only, so a value may contain `=`
///   (`API_TOKEN=abc=def` -> key `API_TOKEN`, value `abc=def`).
/// - Skips blank lines and lines with no `=` (including an empty key like
///   `=value`, which carries no real key).
/// - Trims nothing else: leading/trailing whitespace is preserved, because a
///   script may genuinely want ` KEY` (and trimming would silently change input).
///
/// Pure and VM-free, so it's unit-testable without booting CRuby (see
/// `IntentOutputTests`). Returns `[]` for empty text.
nonisolated func parseEnv(_ text: String) -> [(key: String, value: String)] {
    var pairs: [(key: String, value: String)] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        // `firstIndex(of: "=")` is nil for lines with no `=`; `eq == startIndex`
        // rejects an empty key (`=value`). Both skip without a pair.
        guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
        let key = String(line[..<eq])
        let value = String(line[line.index(after: eq)...])
        pairs.append((key: key, value: value))
    }
    return pairs
}
