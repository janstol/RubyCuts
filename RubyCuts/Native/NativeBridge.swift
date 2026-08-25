import Foundation

/// A native capability's handler: receives the string arguments Ruby passed
/// to `RubyCuts::Native.invoke`, and returns the string result (or `nil`)
/// that comes back as Ruby `nil`.
///
/// String-typed on both ends because every current capability is strings in,
/// string-or-nil out -- the JSON envelope crossing the C boundary is the
/// flexible part. Widening this signature later (richer argument or return
/// types) is additive: it changes neither the C ABI nor the
/// `RubyCuts::Native.invoke` prelude, both of which only ever see JSON.
typealias NativeHandler = @MainActor ([String]) throws -> String?

/// An error a native handler throws, surfaced to Ruby as a
/// `RubyCuts::NativeError` carrying `message`.
struct NativeBridgeError: Error, Sendable {
    let message: String
}

/// The Swift-side registry a Ruby script reaches through `RubyCuts::Native.call`,
/// and the C trampoline (below, at file scope) that connects it to the shim's
/// `rubycuts_native_handler` typedef.
///
/// The registry is injectable: a test registers a handler under a private
/// name and drives it through `RubyCuts::Native.invoke` without touching any
/// real system state, which is what makes the *mechanism* testable
/// independently of the capabilities built on it.
@MainActor
final class NativeBridge {
    static let shared = NativeBridge()

    private var handlers: [String: NativeHandler] = [:]

    private init() {}

    /// Registers `handler` under `name`, replacing any existing handler for
    /// that name. Each capability's `register(in:)` calls this once per
    /// capability name it exposes.
    func register(_ name: String, handler: @escaping NativeHandler) {
        handlers[name] = handler
    }

    /// Registers every built-in capability and returns the concatenated Ruby
    /// prelude that defines their `Device::*` surface on top of
    /// `RubyCuts::Native.invoke`. Called once per boot from
    /// `RubyRuntime.installNativeBridge()`.
    static func installDefaults() -> String {
        ClipboardCapability.register(in: shared)
        NotificationCapability.register(in: shared)
        return [
            invokePrelude,
            ClipboardCapability.preludeSource,
            NotificationCapability.preludeSource,
        ].joined(separator: "\n")
    }

    /// The `RubyCuts::Native.invoke` wrapper every capability's Ruby surface
    /// calls through. Requires `json` (already a statically-linked, proven
    /// extension -- see `RubyRuntimeTests.requiresJSON`) and marshals `call`'s
    /// C-string JSON boundary: `JSON.generate(args)` out,
    /// `JSON.parse(result_json).first` back. The trailing `.first` unwraps
    /// the one-element result array the trampoline below always returns --
    /// wrapping the result that way (rather than a bare JSON scalar) sidesteps
    /// `JSON.parse`'s top-level-scalar ambiguity, the same reasoning `RunInput`
    /// uses base64 for in the other direction.
    ///
    /// Re-tags string arguments as UTF-8 before generating: a string that
    /// reached the script via `Base64.decode64`, `File.binread`, or similar
    /// carries the BINARY encoding even when its bytes are perfectly valid
    /// UTF-8 (e.g. round-tripped from a UTF-8 source), and `JSON.generate`
    /// warns -- soon raises, in json 3.0 -- on a BINARY string it can't
    /// verify. `dup` avoids mutating the caller's string; genuinely invalid
    /// byte sequences still fail in `JSON.generate` afterward, just with a
    /// clear encoding error instead of a silent mislabel.
    private static let invokePrelude = """
        require 'json'

        module RubyCuts
          module Native
            def self.invoke(name, *args)
              utf8_args = args.map { |a| a.is_a?(String) ? a.dup.force_encoding(Encoding::UTF_8) : a }
              JSON.parse(call(name, JSON.generate(utf8_args))).first
            end
          end
        end
        """

    /// Dispatches one call from Ruby: looks up `name`'s handler, JSON-decodes
    /// `argsJSON` into `[String]`, runs the handler, and JSON-encodes the
    /// result back into the one-element array `rc_native_call` expects.
    /// Failures (unknown name, bad JSON, a non-string argument, or the
    /// handler throwing) come back as `.failure` with a human-readable
    /// message -- the trampoline turns that into the shim's `*error_out`.
    fileprivate func dispatch(name: String, argsJSON: String) -> Result<String, NativeBridgeError> {
        guard let handler = handlers[name] else {
            return .failure(NativeBridgeError(message: "unknown native capability '\(name)'"))
        }

        let args: [String]
        do {
            args = try Self.decodeArgs(argsJSON)
        } catch {
            return .failure(
                NativeBridgeError(message: "invalid arguments for '\(name)': \(error)")
            )
        }

        do {
            let value = try handler(args)
            return .success(Self.encodeResult(value))
        } catch let error as NativeBridgeError {
            return .failure(error)
        } catch {
            return .failure(NativeBridgeError(message: "\(error)"))
        }
    }

    /// Decodes the JSON array of arguments Ruby sent. Every element must be a
    /// JSON string -- a non-string argument (number, bool, nested
    /// array/object, null) is rejected rather than silently coerced, matching
    /// the handler contract's string-in guarantee.
    private static func decodeArgs(_ json: String) throws -> [String] {
        guard let data = json.data(using: .utf8) else {
            throw NativeBridgeError(message: "arguments were not valid UTF-8")
        }
        return try JSONDecoder().decode([String].self, from: data)
    }

    /// Encodes `value` as the one-element JSON array Swift returns across the
    /// boundary -- `[null]` for `nil`, `["text"]` otherwise. The prelude reads
    /// `.first` off the parsed result.
    private static func encodeResult(_ value: String?) -> String {
        guard let data = try? JSONEncoder().encode([value]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "[null]"
        }
        return json
    }
}

/// The C-ABI trampoline `rubycuts_install_native_bridge` is given. C function
/// pointers can't capture context, so this reaches the registry through
/// `NativeBridge.shared`; a plain top-level function with no captures is what
/// lets Swift convert it implicitly to a `rubycuts_native_handler`.
///
/// Calling `MainActor.assumeIsolated` here is sound, not a shortcut:
/// `RubyRuntime` is pinned to `@MainActor`, and the VM's stack bounds were
/// recorded on the main thread by `RUBY_INIT_STACK` at boot -- every Ruby
/// frame that can reach `RubyCuts::Native.call` (and therefore this
/// trampoline) is provably running on the main thread already.
nonisolated func rubycutsNativeTrampoline(
    _ namePointer: UnsafePointer<CChar>?,
    _ argsJSONPointer: UnsafePointer<CChar>?,
    _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> UnsafeMutablePointer<CChar>? {
    guard let namePointer, let argsJSONPointer else {
        errorOut?.pointee = strdup("native bridge called with a null argument")
        return nil
    }
    let name = String(cString: namePointer)
    let argsJSON = String(cString: argsJSONPointer)

    // Only Sendable values (String) cross into the @MainActor closure --
    // `errorOut` stays out here, since UnsafeMutablePointer isn't Sendable and
    // there's no need to touch it from inside anyway.
    let outcome = MainActor.assumeIsolated {
        NativeBridge.shared.dispatch(name: name, argsJSON: argsJSON)
    }

    switch outcome {
    case .success(let resultJSON):
        return strdup(resultJSON)
    case .failure(let error):
        errorOut?.pointee = strdup(error.message)
        return nil
    }
}
