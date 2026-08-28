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
    /// Still populated when ``wasCancelled`` is `true` -- a cancelled run is a
    /// failed run that happens to have a known cause, and whatever the script
    /// printed to `$stdout` before the cancellation is still in ``stdout``.
    var errorMessage: String?

    /// The raised exception's `backtrace`, one frame per element. Empty on a
    /// clean run and on non-exception control-flow failures -- see the type's
    /// doc comment.
    var backtrace: [String] = []

    /// `true` when the run was stopped by ``RubyRuntime/requestCancel()`` (or
    /// the ``RubyRuntime/runCancellable(_:input:)`` task being cancelled)
    /// rather than raising or completing on its own.
    var wasCancelled: Bool = false

    /// `true` when the script raised. Convenience for the view layer.
    var hasError: Bool { errorMessage != nil }
}
