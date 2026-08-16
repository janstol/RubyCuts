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
