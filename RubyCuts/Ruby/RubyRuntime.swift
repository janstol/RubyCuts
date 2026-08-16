import Foundation

/// An error raised while evaluating Ruby code through ``RubyRuntime``.
enum RubyError: Error {
    /// Evaluation failed, either because `code` didn't parse or because it raised. The associated string is the Ruby exception's `to_s`, e.g. `"undefined method 'foo' for nil"`.
    case evaluationFailed(String)
}

/// A single embedded CRuby VM, booted once and reused for the life of the process.
///
/// Ruby's VM isn't thread-safe, and `RUBY_INIT_STACK` (expanded inside `rubycuts_init`) records the *initializing thread's* stack bounds for the garbage collector to scan -- every call into the VM has to happen from that same thread afterward. Pinning this type to `@MainActor` is the simplest way to guarantee that.
///
/// **Known follow-up:** because every call runs on the main actor, a long-running script blocks the UI. Giving Ruby its own dedicated thread is a real redesign -- the VM would need to move off `@MainActor` entirely, and every call site would need to hop threads -- not a small addition, so it's left for a later phase rather than smuggled in here.
@MainActor
final class RubyRuntime {
    /// The process-wide Ruby VM. `ruby_init` can't be re-run once the VM is torn down (which this type never does), so this is the only instance to use.
    static let shared = RubyRuntime()

    private init() {}

    /// Evaluates `code` as Ruby and returns the result's `to_s`.
    ///
    /// Boots the VM on first call; later calls reuse it, so top-level state (variables, defined constants, `require`d libraries) persists across evaluations.
    ///
    /// - Parameter code: Ruby source to evaluate.
    /// - Returns: The evaluated result, converted with `to_s`.
    /// - Throws: `RubyError.evaluationFailed` if `code` fails to parse or raises.
    func evaluate(_ code: String) throws -> String {
        // Safe to call on every evaluation: rubycuts_init() no-ops after the first call.
        rubycuts_init()

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = code.withCString { codePointer in
            rubycuts_eval_to_string(codePointer, &errorMessage)
        }

        if let result {
            defer { rubycuts_free(result) }
            return String(cString: result)
        }

        defer { if let errorMessage { rubycuts_free(errorMessage) } }
        let message = errorMessage.map { String(cString: $0) } ?? "unknown Ruby error"
        throw RubyError.evaluationFailed(message)
    }
}
