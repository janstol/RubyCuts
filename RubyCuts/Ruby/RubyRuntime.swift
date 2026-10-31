import Foundation

/// An error raised while evaluating Ruby code through ``RubyRuntime``.
enum RubyError: Error, Sendable {
    /// Evaluation failed, either because `code` didn't parse or because it raised. The associated string is the Ruby exception's `to_s`, e.g. `"undefined method 'foo' for nil"`.
    case evaluationFailed(String)

    /// The Ruby VM never came up: either the bundled `stdlib/` resource is missing from the app bundle, or `rubycuts_init` itself reported failure. The associated string describes which.
    case initializationFailed(String)
}

/// A single embedded CRuby VM, booted once and reused for the life of the process.
///
/// Ruby's VM isn't thread-safe, and `RUBY_INIT_STACK` (expanded inside `rubycuts_init`) records the *initializing thread's* stack bounds for the garbage collector to scan. Every call into the VM has to happen from that same thread afterward. This type is an `actor` whose executor is ``RubyVMExecutor``, a dedicated thread that boots the VM on its own entry frame and then services every later call from that same frame. The compiler enforces "always the VM thread" the same way it enforces any other actor's isolation, and callers `await` in rather than blocking whichever thread they're on.
///
/// Every method below is a plain synchronous actor method with no internal
/// suspension point. That's deliberate: a suspension partway through a
/// multi-eval sequence like ``run(_:input:)`` would let another queued job
/// run in between and interleave with it, corrupting things like the
/// ARGV/ENV backup globals that sequence relies on. All the `await` a caller
/// does is the one hop onto the VM thread to run the whole method.
actor RubyRuntime {
    /// The process-wide Ruby VM. `ruby_init` can't be re-run once the VM is torn down (which this type never does), so this is the only instance to use.
    static let shared = RubyRuntime()

    private let vmExecutor = RubyVMExecutor()

    /// Backs this actor with ``vmExecutor`` instead of the default global
    /// executor, so every call into `RubyRuntime` runs on the dedicated VM
    /// thread ``RubyVMExecutor`` owns.
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        vmExecutor.asUnownedSerialExecutor()
    }

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
    /// Five short evals per run: cheap, and it leaves the C shim untouched.
    ///
    /// **Non-throwing on purpose:** so stdout/stderr captured *before* a raise
    /// survive alongside the error message (the console shows all three), which
    /// ``evaluate``'s `throws` path would drop. Boot failure is returned as a
    /// `RunResult` with `errorMessage` set, not thrown.
    ///
    /// **Known follow-up:** the main actor is free while this runs (callers
    /// `await` it), but `run` itself is still one synchronous unit on the VM
    /// thread. The "live console" streams only after the run completes, not
    /// as it goes. Streaming needs a hook inside the eval loop itself, not
    /// just getting off the main actor. For typical short scripts the run is
    /// instant either way.
    ///
    /// **Not cancellable.** Use ``runCancellable(_:input:)`` for a run the
    /// caller may need to stop; see its doc comment for how cancellation
    /// works and what it can't interrupt.
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
    /// no string-escaping and it round-trips arbitrary bytes, including NULs.
    /// The base64 transport lives here, not in the script: a user's `.rb` just
    /// reads `ARGV[0]`, `$stdin.read`, `ENV["KEY"]` as normal Ruby.
    ///
    /// **Teardown always runs:** the `defer` restores `$stdout`/`$stderr` and,
    /// when input was provided, ARGV/`$stdin`/ENV, even if `code` raised. ENV
    /// teardown restores each key to its prior value (or deletes it if it was
    /// absent before setup set it), so a value a Shortcut run set never leaks
    /// into a later console `evaluate("ENV['X']")` or the next run.
    ///
    /// **Known follow-up:** if the script reassigns `$stdout`/`$stderr` itself,
    /// that output isn't captured. Arguably correct (the script redirected
    /// it), and an edge case for V1.
    ///
    /// On a raise, ``RunResult/backtrace`` carries the Ruby frames from the
    /// exception's `backtrace`, read via the C shim's `$rc_last_error` global
    /// before it can be overwritten by a later eval. Empty on a clean run and
    /// on non-exception control-flow failures (a top-level `return`/`break`/
    /// `throw`), which have no exception object to read frames from.
    func run(_ code: String, input: RunInput = .empty) -> RunResult {
        run(code, input: input, cancellation: nil)
    }

    /// The shared body of ``run(_:input:)`` and ``runCancellable(_:input:)``.
    /// With a `cancellation`, a run already cancelled by the time this job
    /// reaches the VM thread returns at once without evaluating anything, and
    /// otherwise the cancellation hook watches that run, and only that run,
    /// while its user code executes.
    private func run(
        _ code: String, input: RunInput, cancellation: RunCancellation?
    ) -> RunResult {
        if let cancellation, cancellation.isCancelled {
            var result = RunResult(
                stdout: "", stderr: "", result: "", errorMessage: "run cancelled")
            result.wasCancelled = true
            return result
        }

        do {
            try bootIfNeeded()
        } catch {
            return RunResult(
                stdout: "", stderr: "", result: "",
                errorMessage: Self.describe(error)
            )
        }

        // Redirect $stdout/$stderr to StringIO. Fixed string, no user code,
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
        // no-input path is exactly today's five-eval capture; the base64
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

        // The hook is installed only around the user-code eval, never
        // around boot, the StringIO setup above, the input setup/teardown,
        // the backtrace read below, or the $cap_out/$cap_err reads, all of
        // which would otherwise raise if a request lands on them instead.
        if let cancellation {
            rubycuts_cancel_hook_enable(cancellation.handle)
        }
        var evalFailed = false
        let clock = ContinuousClock()
        let start = clock.now
        do {
            result.result = try evalRaw(code)
        } catch {
            result.errorMessage = Self.describe(error)
            // Read the backtrace here, before anything else evals. The shim
            // stashes the exception (or nil) in $rc_last_error on every failed
            // eval, and the next eval below (reading $cap_out) would otherwise
            // overwrite it before we get a chance to read this failure's trace.
            result.backtrace = readBacktrace()
            evalFailed = true
        }
        result.duration = Self.seconds(clock.now - start)
        result.finishedAt = .now
        // Must run before the $cap_out/$cap_err reads below, which would
        // otherwise trip the hook themselves. Gating on evalFailed (the eval
        // actually failed) means a script that deliberately `rescue
        // Exception`s the cancellation and runs to completion isn't reported
        // as cancelled.
        if cancellation != nil {
            result.wasCancelled = rubycuts_cancel_hook_disable() == 1 && evalFailed
        }

        // Read back whatever was printed before the run ended (or raised).
        result.stdout = (try? evalRaw("$cap_out.string")) ?? ""
        result.stderr = (try? evalRaw("$cap_err.string")) ?? ""
        return result
    }

    /// Runs `code` the same as ``run(_:input:)``, but cancels it if the
    /// calling `Task` is cancelled. The entry point both the console
    /// (``ScriptEditorView``'s Stop button) and Shortcuts (a cancelled
    /// intent) should use instead of calling `run` directly.
    ///
    /// Each call gets its own ``RunCancellation``, so cancelling one caller's
    /// task affects only that caller's run, even while another run occupies
    /// the VM thread. `withTaskCancellationHandler`'s `onCancel` runs
    /// synchronously on whatever thread cancels, outside the actor, so it
    /// reaches the VM thread out of band, with no actor hop and no lock:
    ///
    /// - Cancelled while still queued behind another run: the job sees the
    ///   flag when it starts and returns without evaluating anything.
    /// - Cancelled while its user code runs: a `RUBY_EVENT_LINE |
    ///   RUBY_EVENT_CALL | RUBY_EVENT_B_CALL` hook raises
    ///   `RubyCuts::Cancelled` at the next Ruby-level checkpoint. It can't
    ///   interrupt a script blocked inside a single C call (`sleep`, a
    ///   `Net::HTTP` read, a catastrophic regex): cancellation is partial
    ///   (between Ruby statements, not mid-syscall), not a kill switch.
    /// - Cancelled after it finished: nothing reads that run's flag any more,
    ///   so a later run is unaffected.
    nonisolated func runCancellable(_ code: String, input: RunInput = .empty) async -> RunResult {
        let cancellation = RunCancellation()
        return await withTaskCancellationHandler {
            await run(code, input: input, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Evaluates `code` against the already-booted VM. The caller must have booted
    /// first (via `bootIfNeeded`); this is the no-boot wrapper `evaluate` builds
    /// on, and the one boot itself uses for one-time setup that mustn't re-enter
    /// `bootIfNeeded` (which `evaluate` would do).
    ///
    /// The shim hands both the result and the error message back as a
    /// length-delimited buffer, so a string with an embedded NUL (`"a\0b"`)
    /// arrives whole instead of being cut off at the NUL.
    private func evalRaw(_ code: String) throws -> String {
        var output = rubycuts_buffer()
        let succeeded = code.withCString { codePointer in
            rubycuts_eval(codePointer, &output)
        }
        defer { rubycuts_free(output.bytes) }

        let text = Self.string(from: output)
        guard succeeded == 1 else {
            throw RubyError.evaluationFailed(text)
        }
        return text
    }

    /// Decodes a shim buffer as UTF-8, reading exactly `length` bytes so
    /// embedded NULs are kept. Invalid UTF-8 (a binary Ruby string) is
    /// repaired with replacement characters rather than rejected, the same
    /// leniency `String(cString:)` had before.
    ///
    /// `nonisolated`: a pure conversion called from ``evalRaw(_:)`` on the VM
    /// thread.
    private nonisolated static func string(from buffer: rubycuts_buffer) -> String {
        guard let bytes = buffer.bytes, buffer.length > 0 else { return "" }
        let raw = UnsafeRawBufferPointer(start: bytes, count: Int(buffer.length))
        return String(decoding: raw, as: UTF8.self)
    }

    /// Boots the VM if it hasn't already. Safe to call on every evaluation: `rubycuts_init` no-ops after the first successful call.
    private func bootIfNeeded() throws {
        guard let stdlibURL = Self.bundledStdlibURL() else {
            throw RubyError.initializationFailed(
                "bundled CRuby stdlib resource not found. Run scripts/build-cruby.rb and rebuild"
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
        installGemPaths()
    }

    /// Overrides `Kernel#exit!` and `Kernel#abort` to raise a catchable
    /// `SystemExit` instead of terminating the host process.
    ///
    /// `exit!` (and `abort`, which routes through it) calls the real C `exit()`
    /// directly, bypassing `rb_eval_string_protect`'s catch, so a script
    /// containing `exit!` would kill the whole app, not just fail the run. Plain
    /// `exit` already raises `SystemExit`, which `_protect` catches as a normal
    /// exception, so it needs no override. Redefining `exit!`/`abort` in Ruby
    /// shadows the C implementations: a `def` in `module Kernel` replaces the
    /// registered C method, and the raised `SystemExit` is caught downstream as
    /// `TAG_RAISE` and surfaced as a run error, exactly the "script exits ->
    /// run fails" behavior the PRD wants for both the console and App Intents.
    ///
    /// Best-effort and non-fatal: if the redefine fails, Ruby itself still works;
    /// only `exit!`/`abort` would still terminate the host.
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
    /// if the prelude eval fails, Ruby itself still works; only the
    /// `Device::*` capabilities degrade (an undefined-constant `NameError`, or
    /// a `RuntimeError` from `RubyCuts::Native.call` if the C-side handler was
    /// never installed).
    ///
    /// Only the Ruby-side surface (`Device::Clipboard`, `Device::Notification`)
    /// is defined here, from ``NativeBridge/preludeSource``, a `nonisolated`
    /// `String` that needs no actor hop from the VM thread. The Swift-side
    /// handlers those calls eventually dispatch to are registered lazily, on
    /// the main actor, the first time one actually fires; see
    /// ``NativeBridge/registerDefaultsIfNeeded()``.
    private func installNativeBridge() {
        rubycuts_install_native_bridge(rubycutsNativeTrampoline)
        do {
            _ = try evalRaw(NativeBridge.preludeSource)
        } catch {
            // Non-fatal: Device::* capabilities degrade; Ruby itself still works.
        }
    }

    /// Appends every installed gem's `lib/` directory to `$LOAD_PATH`, so a
    /// gem installed in a previous run is requireable from a fresh boot.
    /// `GemInstaller` calls ``appendLoadPath(_:)`` directly right after a
    /// successful install, so a gem is requireable without restarting the
    /// app. This is only the boot-time half of that contract.
    ///
    /// Best-effort and non-fatal, matching the rest of boot: a corrupt or
    /// unreadable gem store just means gems degrade, not that Ruby itself
    /// fails to boot.
    private func installGemPaths() {
        guard let gems = try? GemStore.installedGems.list() else { return }
        for gem in gems {
            appendLoadPath(gem.libURL)
        }
    }

    /// Appends `directory` to `$LOAD_PATH` if it isn't already there.
    ///
    /// **Append, never prepend:** ``configureTLS()`` reads `$LOAD_PATH.first`
    /// to locate `cacert.pem`, and stdlib should always win over a
    /// same-named gem. The path crosses into Ruby base64-encoded via
    /// ``base64(_:)``, the same transport ``run(_:input:)`` uses, so
    /// arbitrary path characters need no Ruby string-escaping.
    ///
    /// Best-effort: a failed eval here just means one gem's directory
    /// doesn't join `$LOAD_PATH`, not that the caller's larger operation
    /// (boot, or a fresh install) fails.
    func appendLoadPath(_ directory: URL) {
        let pathB64 = Self.base64(directory.path)
        let code = """
            require 'base64'
            path = Base64.decode64("\(pathB64)")
            $LOAD_PATH << path unless $LOAD_PATH.include?(path)
            """
        _ = try? evalRaw(code)
    }

    /// Eagerly loads the sanitized `rbconfig.rb` so `RbConfig` is defined at boot,
    /// matching a normal MRI boot (see ``bootIfNeeded``). Best-effort and
    /// non-fatal: if the file is missing or rejected, Ruby itself still works;
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
    /// via `try?`, matching how ``configureTLS()``/``loadRbConfig()`` degrade:
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
    /// shared default cert store so `Net::HTTP` over HTTPS can verify peers,
    /// and redefines `OpenSSL::X509::Store#set_default_paths` to do the same
    /// for any *other* store a gem builds itself.
    ///
    /// OpenSSL's compiled-in `--openssldir` is a build-machine path that doesn't
    /// exist on device, so `OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE.set_default_paths` (run when `openssl/ssl.rb` loads) finds no trusted roots and every
    /// HTTPS request fails with "unable to get local issuer certificate". Populating
    /// that one shared store with our bundled PEM, which `Net::HTTP`'s
    /// `SSLContext#set_params` assigns to every connection that doesn't set its own
    /// `cert_store`, fixes verification with no per-call configuration and no
    /// `SSL_CERT_FILE` env var (Ruby's openssl ext doesn't honor one). `$LOAD_PATH.first` is the bundled stdlib dir (the single load-path entry), so the PEM is
    /// locatable in Ruby without a Swift-to-Ruby path round-trip.
    ///
    /// **The `set_default_paths` override is what Phase 7 gems need.** A gem
    /// isn't obligated to rely on `Net::HTTP`'s `DEFAULT_CERT_STORE`
    /// fallback: `httparty`, for one, builds its own
    /// `OpenSSL::X509::Store.new.tap { |s| s.set_default_paths }` and assigns
    /// it directly as `http.cert_store`, bypassing `DEFAULT_CERT_STORE`
    /// entirely. Since the real system default paths are always empty on
    /// this platform anyway, redefining `set_default_paths` to load the
    /// bundled PEM instead, for every `X509::Store` and not just
    /// `DEFAULT_CERT_STORE`, fixes that gem and any future one built the
    /// same way, without a per-gem patch.
    ///
    /// Best-effort and non-fatal: if the bundle is missing or rejected, Ruby itself
    /// still works; only TLS peer verification degrades (failing later with a
    /// cert error). Requiring openssl here is eager, but only when a bundle is
    /// present, and it's a one-time cost on the first `evaluate` (boot).
    private func configureTLS() {
        guard Self.bundledCACertURL() != nil else { return }
        let code = """
            require 'openssl'
            OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE.add_file(File.join($LOAD_PATH.first, 'cacert.pem'))
            class OpenSSL::X509::Store
              def set_default_paths
                add_file(File.join($LOAD_PATH.first, 'cacert.pem'))
              end
            end
            """
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
    ///
    /// `nonisolated`: a pure string builder called synchronously from
    /// ``run(_:input:)``, which runs on the VM thread, not the main actor:
    /// without this it would default to `@MainActor` (this app target's
    /// default isolation) and that call wouldn't compile.
    private nonisolated static func inputSetup(for input: RunInput) -> String {
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
    /// code raised. The point is a Shortcut run's env never bleeds into a
    /// later console evaluation or the next run.
    ///
    /// `nonisolated`, matching ``inputSetup(for:)``: called synchronously
    /// from `run`'s VM-thread-isolated `defer`.
    private nonisolated static func inputTeardown(for input: RunInput) -> String {
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
    ///
    /// Internal (not `private`) so ``GemArchive`` can reuse the same
    /// transport for filesystem paths, rather than re-deriving it.
    ///
    /// `nonisolated`: called synchronously from ``appendLoadPath(_:)`` (VM-
    /// thread-isolated) as well as from other actors entirely: a pure
    /// function with no VM or main-actor state, so it needs no isolation of
    /// its own.
    nonisolated static func base64(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
    }

    /// Converts a ``ContinuousClock`` measurement to seconds for
    /// ``RunResult/duration``. `ContinuousClock` is monotonic and unaffected
    /// by wall-clock adjustments, the right clock for timing a single eval.
    ///
    /// `nonisolated`: called synchronously from `run`, which runs on the VM
    /// thread, not the main actor.
    private nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Maps a thrown ``RubyError`` to a short human-readable string for
    /// ``run(_:)``'s `errorMessage` field. `evaluate` throws the same error;
    /// `run` catches it and surfaces the message instead.
    ///
    /// `nonisolated`: called synchronously from `run`, which runs on the VM
    /// thread, not the main actor.
    private nonisolated static func describe(_ error: Error) -> String {
        if let rubyError = error as? RubyError {
            switch rubyError {
            case .evaluationFailed(let message): return message
            case .initializationFailed(let message): return message
            }
        }
        return error.localizedDescription
    }

    /// Locates the bundled CA bundle: `stdlib/cacert.pem`. Returns `nil` if the
    /// stdlib or the PEM is missing: a build that skipped the
    /// `install_ca_bundle!` step in `scripts/build-cruby.rb`.
    ///
    /// `nonisolated`: called synchronously from ``configureTLS()``, which
    /// runs on the VM thread, not the main actor.
    private nonisolated static func bundledCACertURL() -> URL? {
        guard let stdlibURL = bundledStdlibURL() else { return nil }
        let cacertURL = stdlibURL.appending(component: "cacert.pem")
        return FileManager.default.fileExists(atPath: cacertURL.path) ? cacertURL : nil
    }

    /// Locates the bundled CRuby stdlib directory: `RubyCuts.app/Contents/Resources/stdlib` on macOS, `RubyCuts.app/stdlib` on iOS. `RubyCutsTests` is app-hosted (`TEST_HOST`/`BUNDLE_LOADER` in the project), so `Bundle.main` during a test run resolves to `RubyCuts.app` too.
    ///
    /// - Returns: The resource's URL, or `nil` if it's missing: a build that skipped `scripts/build-cruby.rb`, or a stale bundle from before this resource was wired up.
    ///
    /// `nonisolated`: called synchronously from ``bootIfNeeded()`` and
    /// ``bundledCACertURL()``, both of which run on the VM thread, not the
    /// main actor.
    private nonisolated static func bundledStdlibURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let stdlibURL = resourceURL.appending(component: "stdlib", directoryHint: .isDirectory)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stdlibURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }

        return stdlibURL
    }
}

/// One ``RubyRuntime/runCancellable(_:input:)`` call's cancellation state: a
/// Swift owner for the C shim's per-run `rubycuts_run`.
///
/// `@unchecked Sendable` because the only mutable state is the C struct's
/// atomic flag, which the shim reads and writes atomically from any thread.
/// The object outlives every reader of the handle: `runCancellable` holds it
/// for the whole call, and the VM thread only dereferences it between hook
/// enable and disable, inside that call.
private nonisolated final class RunCancellation: @unchecked Sendable {
    /// The C state the event hook reads while this run is active.
    let handle: OpaquePointer

    init() {
        guard let handle = rubycuts_run_create() else {
            fatalError("out of memory allocating run cancellation state")
        }
        self.handle = handle
    }

    deinit {
        rubycuts_run_destroy(handle)
    }

    /// Whether ``cancel()`` has been called, from any thread.
    var isCancelled: Bool {
        rubycuts_run_is_cancelled(handle) != 0
    }

    /// Marks this run, and only this run, as cancelled.
    func cancel() {
        rubycuts_run_cancel(handle)
    }
}
