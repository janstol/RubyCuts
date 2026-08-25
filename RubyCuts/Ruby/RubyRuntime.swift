import Foundation

/// An error raised while evaluating Ruby code through ``RubyRuntime``.
enum RubyError: Error {
    /// Evaluation failed, either because `code` didn't parse or because it raised. The associated string is the Ruby exception's `to_s`, e.g. `"undefined method 'foo' for nil"`.
    case evaluationFailed(String)

    /// The Ruby VM never came up: either the bundled `stdlib/` resource is missing from the app bundle, or `rubycuts_init` itself reported failure. The associated string describes which.
    case initializationFailed(String)
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
        try bootIfNeeded()
        return try evalRaw(code)
    }

    /// Runs `code` as a script with `$stdout`/`$stderr` captured, returning a
    /// ``RunResult`` holding the captured output, the last expression's `to_s`,
    /// and the exception message if it raised.
    ///
    /// Capture is done entirely in Ruby, not in the C shim: a fixed setup string
    /// redirects `$stdout`/`$stderr` to `StringIO` objects stashed in `$cap_out`
    /// /`$cap_err`, then `code` runs via ``evalRaw`` (the same path
    /// ``evaluate`` uses, so user code never gets string-escaped into a wrapper),
    /// then the captured strings are read back and `$stdout`/`$stderr` restored.
    /// Five short evals per run -- cheap, and it leaves the C shim untouched.
    ///
    /// **Non-throwing on purpose:** so stdout/stderr captured *before* a raise
    /// survive alongside the error message (the console shows all three), which
    /// ``evaluate``'s `throws` path would drop. Boot failure is returned as a
    /// `RunResult` with `errorMessage` set, not thrown.
    ///
    /// **Known follow-up:** like ``evaluate``, this is synchronous and runs on
    /// the main actor, so a long-running script blocks the UI -- the "live
    /// console" streams only after the run completes, not as it goes. True
    /// streaming needs the VM off the main actor (the redesign flagged on this
    /// type), and is deferred. For typical short scripts the run is instant.
    ///
    /// **Input is opt-in.** With an empty ``RunInput`` (the default) this is
    /// byte-for-byte today's path: the five-eval StringIO capture, no
    /// `require 'base64'`, no ARGV/`$stdin`/ENV setup, so the in-app console and
    /// every existing caller pay zero overhead. A non-empty `input` runs one
    /// extra setup eval before `code` (and one teardown eval in the existing
    /// `defer`) that injects *only* the channels `input` provides, via base64:
    /// Swift base64-encodes the values into plain ASCII literals and Ruby
    /// `Base64.decode64`s them back. Base64 is safe in a double-quoted literal
    /// (its alphabet is `A-Za-z0-9+/=`, no quotes/backslashes/`#{}`), so there's
    /// no string-escaping and it round-trips arbitrary bytes -- including NULs.
    /// The base64 transport lives here, not in the script: a user's `.rb` just
    /// reads `ARGV[0]`, `$stdin.read`, `ENV["KEY"]` as normal Ruby.
    ///
    /// **Teardown always runs:** the `defer` restores `$stdout`/`$stderr` and,
    /// when input was provided, ARGV/`$stdin`/ENV -- even if `code` raised. ENV
    /// teardown restores each key to its prior value (or deletes it if it was
    /// absent before setup set it), so a value a Shortcut run set never leaks
    /// into a later console `evaluate("ENV['X']")` or the next run.
    ///
    /// **Known follow-up:** if the script reassigns `$stdout`/`$stderr` itself,
    /// that output isn't captured -- arguably correct (the script redirected
    /// it), and an edge case for V1.
    ///
    /// On a raise, ``RunResult/backtrace`` carries the Ruby frames from the
    /// exception's `backtrace`, read via the C shim's `$rc_last_error` global
    /// before it can be overwritten by a later eval. Empty on a clean run and
    /// on non-exception control-flow failures (a top-level `return`/`break`/
    /// `throw`), which have no exception object to read frames from.
    func run(_ code: String, input: RunInput = .empty) -> RunResult {
        do {
            try bootIfNeeded()
        } catch {
            return RunResult(
                stdout: "", stderr: "", result: "",
                errorMessage: Self.describe(error)
            )
        }

        // Redirect $stdout/$stderr to StringIO. Fixed string -- no user code,
        // so no escaping concerns. Best-effort: if `require 'stringio'` fails
        // (stringio should be a statically-linked extension), the run still
        // proceeds, just with empty captured streams.
        _ = try? evalRaw(
            "require 'stringio'; "
                + "$cap_out = StringIO.new; $cap_err = StringIO.new; "
                + "$stdout = $cap_out; $stderr = $cap_err"
        )

        // Inject ARGV/$stdin/ENV only when the caller actually provided input.
        // An empty RunInput skips this (and the matching teardown below), so the
        // no-input path is exactly today's five-eval capture -- the base64
        // transport never runs.
        let hasInput = !input.isEmpty
        if hasInput {
            _ = try? evalRaw(Self.inputSetup(for: input))
        }
        // Always restore, even if `code` raises (evalRaw throws on raise). Input
        // teardown fires before the stdout/stderr restore; it touches ARGV/
        // $stdin/ENV only, so it doesn't affect the captured buffers already
        // read above the restore.
        defer {
            if hasInput {
                _ = try? evalRaw(Self.inputTeardown(for: input))
            }
            _ = try? evalRaw("$stdout = STDOUT; $stderr = STDERR")
        }

        var result = RunResult(stdout: "", stderr: "", result: "", errorMessage: nil)
        do {
            result.result = try evalRaw(code)
        } catch {
            result.errorMessage = Self.describe(error)
            // Read the backtrace here, before anything else evals -- the shim
            // stashes the exception (or nil) in $rc_last_error on every failed
            // eval, and the next eval below (reading $cap_out) would otherwise
            // overwrite it before we get a chance to read this failure's trace.
            result.backtrace = readBacktrace()
        }

        // Read back whatever was printed before the run ended (or raised).
        result.stdout = (try? evalRaw("$cap_out.string")) ?? ""
        result.stderr = (try? evalRaw("$cap_err.string")) ?? ""
        return result
    }

    /// Evaluates `code` against the already-booted VM. The caller must have booted
    /// first (via `bootIfNeeded`); this is the no-boot wrapper `evaluate` builds
    /// on, and the one boot itself uses for one-time setup that mustn't re-enter
    /// `bootIfNeeded` (which `evaluate` would do).
    private func evalRaw(_ code: String) throws -> String {
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

    /// Boots the VM if it hasn't already. Safe to call on every evaluation: `rubycuts_init` no-ops after the first successful call.
    private func bootIfNeeded() throws {
        guard let stdlibURL = Self.bundledStdlibURL() else {
            throw RubyError.initializationFailed(
                "bundled CRuby stdlib resource not found -- run scripts/build-cruby.rb and rebuild"
            )
        }

        let status = stdlibURL.withUnsafeFileSystemRepresentation { path in
            rubycuts_init(path)
        }
        guard status == 0 else {
            throw RubyError.initializationFailed("rubycuts_init failed with status \(status)")
        }

        // Match a normal `ruby` interpreter boot, which has `RbConfig` defined
        // from the first line of any script. A normal boot gets that from
        // RubyGems bootstrap (it requires rbconfig during startup); `rubycuts_init`
        // boots with `--disable-gems`, so that bootstrap is skipped and `RbConfig`
        // is never defined. Without this, stdlib files that reference `RbConfig`
        // without an explicit `require 'rbconfig'` (resolv.rb's `WINDOWS`
        // constant, fileutils.rb, ...) raise
        // `NameError: uninitialized constant RbConfig` in a fresh process.
        // The sanitized `rbconfig.rb` is on `$LOAD_PATH` (sanitize_rbconfig! in
        // scripts/build-cruby.rb), so `require 'rbconfig'` resolves it.
        loadRbConfig()
        configureTLS()
        hardenProcessExit()
        installNativeBridge()
    }

    /// Overrides `Kernel#exit!` and `Kernel#abort` to raise a catchable
    /// `SystemExit` instead of terminating the host process.
    ///
    /// `exit!` (and `abort`, which routes through it) calls the real C `exit()`
    /// directly, bypassing `rb_eval_string_protect`'s catch -- so a script
    /// containing `exit!` would kill the whole app, not just fail the run. Plain
    /// `exit` already raises `SystemExit`, which `_protect` catches as a normal
    /// exception, so it needs no override. Redefining `exit!`/`abort` in Ruby
    /// shadows the C implementations: a `def` in `module Kernel` replaces the
    /// registered C method, and the raised `SystemExit` is caught downstream as
    /// `TAG_RAISE` and surfaced as a run error -- exactly the "script exits ->
    /// run fails" behavior the PRD wants for both the console and App Intents.
    ///
    /// Best-effort and non-fatal: if the redefine fails, Ruby itself still works
    /// -- only `exit!`/`abort` would still terminate the host.
    private func hardenProcessExit() {
        let code = """
            module Kernel
              def exit!(status = true)
                code = case status
                       when true then 0
                       when false then 1
                       when nil then 0
                       else status.to_i
                       end
                raise SystemExit.new(code)
              end
              def abort(msg = nil)
                $stderr.puts msg if msg
                raise SystemExit.new(1)
              end
            end
            """
        do {
            _ = try evalRaw(code)
        } catch {
            // Non-fatal: exit!/abort would still terminate the host.
        }
    }

    /// Installs the Swift-native capability bridge (``NativeBridge``) and evals
    /// the Ruby prelude that defines `Device::Clipboard`/`Device::Notification`
    /// on top of it.
    ///
    /// Best-effort and non-fatal, matching ``loadRbConfig()``/``configureTLS()``:
    /// if the prelude eval fails, Ruby itself still works -- only the
    /// `Device::*` capabilities degrade (an undefined-constant `NameError`, or
    /// a `RuntimeError` from `RubyCuts::Native.call` if the C-side handler was
    /// never installed).
    private func installNativeBridge() {
        rubycuts_install_native_bridge(rubycutsNativeTrampoline)
        do {
            _ = try evalRaw(NativeBridge.installDefaults())
        } catch {
            // Non-fatal: Device::* capabilities degrade; Ruby itself still works.
        }
    }

    /// Eagerly loads the sanitized `rbconfig.rb` so `RbConfig` is defined at boot,
    /// matching a normal MRI boot (see ``bootIfNeeded``). Best-effort and
    /// non-fatal: if the file is missing or rejected, Ruby itself still works --
    /// only `RbConfig`-dependent stdlib paths degrade (failing later with a
    /// `NameError` when something references `RbConfig`).
    private func loadRbConfig() {
        do {
            _ = try evalRaw("require 'rbconfig'")
        } catch {
            // Non-fatal: RbConfig-dependent stdlib paths degrade.
        }
    }

    /// Reads the backtrace of the exception the shim stashed in
    /// `$rc_last_error` for the eval that just failed. `&.` covers
    /// `$rc_last_error` being `nil` (a non-raise tag, or nothing ever set it);
    /// `|| []` covers `Exception#backtrace` itself returning `nil`. Best-effort
    /// via `try?`, matching how ``configureTLS()``/``loadRbConfig()`` degrade --
    /// a failure here just means an empty backtrace, not a failed run.
    ///
    /// Must be called before any other eval runs, since the next failed eval
    /// overwrites `$rc_last_error` (see the shim's `rc_error_message_for_state`).
    private func readBacktrace() -> [String] {
        guard let joined = try? evalRaw(#"($rc_last_error&.backtrace || []).join("\n")"#),
            !joined.isEmpty
        else { return [] }
        return joined.components(separatedBy: "\n")
    }

    /// Loads the bundled Mozilla CA bundle (`stdlib/cacert.pem`) into OpenSSL's
    /// shared default cert store so `Net::HTTP` over HTTPS can verify peers.
    ///
    /// OpenSSL's compiled-in `--openssldir` is a build-machine path that doesn't
    /// exist on device, so `OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE.set_default_paths` (run when `openssl/ssl.rb` loads) finds no trusted roots and every
    /// HTTPS request fails with "unable to get local issuer certificate". Populating
    /// that one shared store with our bundled PEM -- which `Net::HTTP`'s
    /// `SSLContext#set_params` assigns to every connection that doesn't set its own
    /// `cert_store` -- fixes verification with no per-call configuration and no
    /// `SSL_CERT_FILE` env var (Ruby's openssl ext doesn't honor one). `$LOAD_PATH.first` is the bundled stdlib dir (the single load-path entry), so the PEM is
    /// locatable in Ruby without a Swift-to-Ruby path round-trip.
    ///
    /// Best-effort and non-fatal: if the bundle is missing or rejected, Ruby itself
    /// still works -- only TLS peer verification degrades (failing later with a
    /// cert error). Requiring openssl here is eager, but only when a bundle is
    /// present, and it's a one-time cost on the first `evaluate` (boot).
    private func configureTLS() {
        guard Self.bundledCACertURL() != nil else { return }
        let code =
            "require 'openssl'; "
            + "OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE.add_file("
            + "File.join($LOAD_PATH.first, 'cacert.pem'))"
        do {
            _ = try evalRaw(code)
        } catch {
            // Non-fatal: TLS verification degrades; Ruby itself still works.
        }
    }

    /// Builds the one-time setup Ruby that injects `input`'s channels into the
    /// VM before the user's code runs. Each value is base64-encoded by Swift and
    /// decoded in Ruby, so the embedded literals are plain ASCII with no
    /// escaping (see ``run(_:input:)``). Only the channels `input` provides are
    /// set, so a run with ARGV-only doesn't touch `$stdin` or `ENV`.
    private static func inputSetup(for input: RunInput) -> String {
        var parts: [String] = ["require 'base64'"]

        if !input.argv.isEmpty {
            let encoded = input.argv.map { "\"\(base64($0))\"" }.joined(separator: ", ")
            parts.append(
                "$rc_argv_backup = ARGV.dup; "
                    + "ARGV.replace([\(encoded)].map { |s| Base64.decode64(s) })"
            )
        }

        if !input.stdin.isEmpty {
            parts.append(
                "$rc_stdin_backup = $stdin; "
                    + "$stdin = StringIO.new(Base64.decode64(\"\(base64(input.stdin))\"))"
            )
        }

        if !input.env.isEmpty {
            let pairs = input.env.map { (k, v) in
                "[\"\(base64(k))\", \"\(base64(v))\"]"
            }.joined(separator: ", ")
            parts.append(
                "$rc_env_backup = {}; "
                    + "[\(pairs)].each { |k, v| dk = Base64.decode64(k); "
                    + "$rc_env_backup[dk] = ENV[dk]; ENV[dk] = Base64.decode64(v) }"
            )
        }

        return parts.joined(separator: "; ")
    }

    /// Builds the teardown Ruby that restores the channels ``inputSetup(for:)``
    /// mutated, in the same order setup touched them. Restores ARGV and
    /// `$stdin` from their saved backups, and restores each ENV key to its prior
    /// value (deleting it if it was absent before setup set it), then clears the
    /// backup globals. Runs in `run`'s `defer`, so it fires even when the user's
    /// code raised -- the point being a Shortcut run's env never bleeds into a
    /// later console evaluation or the next run.
    private static func inputTeardown(for input: RunInput) -> String {
        var parts: [String] = []

        if !input.argv.isEmpty {
            parts.append("ARGV.replace($rc_argv_backup); $rc_argv_backup = nil")
        }
        if !input.stdin.isEmpty {
            parts.append("$stdin = $rc_stdin_backup; $rc_stdin_backup = nil")
        }
        if !input.env.isEmpty {
            // Parenthesize the assignment: Ruby's ternary binds tighter than
            // `=`, so `v.nil? ? ENV.delete(k) : ENV[k] = v` would mis-parse.
            parts.append(
                "$rc_env_backup.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }; "
                    + "$rc_env_backup = nil"
            )
        }

        return parts.joined(separator: "; ")
    }

    /// Base64-encodes `string` for embedding in a Ruby double-quoted literal.
    /// Standard base64 (with `+`/`/`/`=`) is safe in such a literal: its
    /// alphabet contains no quote, backslash, or `#`, so no Ruby string-escaping
    /// is needed, and it round-trips arbitrary bytes including NULs.
    private static func base64(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
    }

    /// Maps a thrown ``RubyError`` to a short human-readable string for
    /// ``run(_:)``'s `errorMessage` field. `evaluate` throws the same error;
    /// `run` catches it and surfaces the message instead.
    private static func describe(_ error: Error) -> String {
        if let rubyError = error as? RubyError {
            switch rubyError {
            case .evaluationFailed(let message): return message
            case .initializationFailed(let message): return message
            }
        }
        return error.localizedDescription
    }

    /// Locates the bundled CA bundle: `stdlib/cacert.pem`. Returns `nil` if the
    /// stdlib or the PEM is missing -- a build that skipped the
    /// `install_ca_bundle!` step in `scripts/build-cruby.rb`.
    private static func bundledCACertURL() -> URL? {
        guard let stdlibURL = bundledStdlibURL() else { return nil }
        let cacertURL = stdlibURL.appending(component: "cacert.pem")
        return FileManager.default.fileExists(atPath: cacertURL.path) ? cacertURL : nil
    }

    /// Locates the bundled CRuby stdlib directory: `RubyCuts.app/Contents/Resources/stdlib` on macOS, `RubyCuts.app/stdlib` on iOS. `RubyCutsTests` is app-hosted (`TEST_HOST`/`BUNDLE_LOADER` in the project), so `Bundle.main` during a test run resolves to `RubyCuts.app` too.
    ///
    /// - Returns: The resource's URL, or `nil` if it's missing -- a build that skipped `scripts/build-cruby.rb`, or a stale bundle from before this resource was wired up.
    private static func bundledStdlibURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let stdlibURL = resourceURL.appending(component: "stdlib", directoryHint: .isDirectory)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stdlibURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }

        return stdlibURL
    }
}
