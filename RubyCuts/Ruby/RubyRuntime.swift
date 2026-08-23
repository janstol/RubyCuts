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
    /// **Known follow-up:** if the script reassigns `$stdout`/`$stderr` itself,
    /// that output isn't captured -- arguably correct (the script redirected
    /// it), and an edge case for V1.
    func run(_ code: String) -> RunResult {
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
        // Always restore, even if `code` raises (evalRaw throws on raise).
        defer {
            _ = try? evalRaw("$stdout = STDOUT; $stderr = STDERR")
        }

        var result = RunResult(stdout: "", stderr: "", result: "", errorMessage: nil)
        do {
            result.result = try evalRaw(code)
        } catch {
            result.errorMessage = Self.describe(error)
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
