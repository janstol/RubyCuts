import Foundation

/// The outcome of running a script through ``RubyRuntime/run(_:)``: the captured
/// `STDOUT` and `STDERR`, the last expression's `to_s`, and the Ruby exception
/// message if the script raised.
///
/// A plain `Sendable` value type -- all members are `String`/`String?`, so it's
/// safe to pass across actors even though ``RubyRuntime`` itself is
/// `@MainActor`-isolated. The console view holds one of these in `@State`.
///
/// `backtrace` is empty on a clean run, and also on a non-exception
/// control-flow failure (a top-level `return`/`break`/`throw`), since
/// neither has an exception object to read frames from.
struct RunResult: Sendable {
    /// Everything the script wrote to `$stdout` (`puts`, `print`, `$>.write`).
    var stdout: String

    /// Everything the script wrote to `$stderr` (`warn`, `$stderr.puts`, ...).
    var stderr: String

    /// The `to_s` of the last evaluated expression, mirroring what
    /// ``RubyRuntime/evaluate(_:)`` returns. Empty for scripts that end in a
    /// raise or that only call `puts` (whose last expression is `nil`).
    var result: String

    /// The Ruby exception's `to_s` when the script raised; `nil` on a clean run.
    var errorMessage: String?

    /// The raised exception's `backtrace`, one frame per element. Empty on a
    /// clean run and on non-exception control-flow failures -- see the type's
    /// doc comment.
    var backtrace: [String] = []

    /// `true` when the script raised. Convenience for the view layer.
    var hasError: Bool { errorMessage != nil }
}
