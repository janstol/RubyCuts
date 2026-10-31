import Foundation
@testable import RubyCuts
import Testing

// Every test drives the same embedded CRuby VM through `RubyRuntime.shared`,
// which is a single non-thread-safe interpreter. Swift Testing runs tests
// concurrently by default; left that way, two tests racing through
// `require 'net/http'` -> `require 'resolv'` -> `require 'rbconfig'` can
// double-load resolv.rb and leave RbConfig undefined for the loser (seen on
// the iOS Simulator; macOS scheduling happened not to trip it). `.serialized`
// runs the suite's tests one at a time, matching the runtime's single-threaded
// contract. The app itself is unaffected: `RubyRuntime`'s own actor
// isolation already serializes every call onto its one dedicated VM thread,
// one at a time, no matter which actor a caller awaits it from. Nested under
// ``EmbeddedRubyTests`` so `.serialized` covers `NativeBridgeTests` and
// `GemArchiveTests` too; see that type's doc comment.
extension EmbeddedRubyTests {
    @MainActor
    @Suite(.serialized)
    struct RubyRuntimeTests {

        // MARK: - Boot parity with a normal `ruby` interpreter

        @Test func rbConfigIsDefinedAtBoot() async throws {
            // Guards `RubyRuntime.loadRbConfig()` (run from `bootIfNeeded`): a normal
            // `ruby` interpreter loads rbconfig.rb during startup so RbConfig is
            // defined before any code runs, but our minimal `rubycuts_init` boot
            // does not. Without loadRbConfig(), stdlib files that reference RbConfig
            // without an explicit `require 'rbconfig'` (resolv.rb's `WINDOWS`
            // constant, fileutils.rb) raise `NameError: uninitialized constant
            // RbConfig` in a fresh process, which is exactly what the real app
            // hit doing `require 'net/http'`. Placed first in this `.serialized`
            // suite so, in its source-order run, only boot has had a chance to load
            // rbconfig; if boot stops loading it, this fails before later tests
            // (logger, fileutils) mask the regression by loading rbconfig themselves.
            let defined = try await RubyRuntime.shared.evaluate("defined?(RbConfig)")
            #expect(defined == "constant")
        }

        @Test func addsIntegers() async throws {
            #expect(try await RubyRuntime.shared.evaluate("1 + 1") == "2")
        }

        @Test func upcasesAString() async throws {
            #expect(try await RubyRuntime.shared.evaluate("\"hello\".upcase") == "HELLO")
        }

        @Test func reportsRubyVersion() async throws {
            let version = try await RubyRuntime.shared.evaluate("RUBY_VERSION")
            #expect(version.hasPrefix("3.4"))
        }

        @Test func throwsOnSyntaxError() async {
            do {
                _ = try await RubyRuntime.shared.evaluate("def broken(")
                Issue.record("expected evaluate to throw on a syntax error")
            } catch RubyError.evaluationFailed(let message) {
                #expect(!message.isEmpty)
            } catch {
                Issue.record("expected RubyError, got \(error)")
            }
        }

        @Test func throwsOnRaise() async {
            do {
                _ = try await RubyRuntime.shared.evaluate("raise 'boom'")
                Issue.record("expected evaluate to throw when Ruby raises")
            } catch RubyError.evaluationFailed(let message) {
                #expect(!message.isEmpty)
            } catch {
                Issue.record("expected RubyError, got \(error)")
            }
        }

        @Test func vmStatePersistsAcrossEvaluations() async throws {
            _ = try await RubyRuntime.shared.evaluate("$rubycuts_test_counter = 41")
            let result = try await RubyRuntime.shared.evaluate("$rubycuts_test_counter += 1")
            #expect(result == "42")
        }

        // MARK: - Boot completion (rubycuts_init via ruby_options, not bare ruby_init)

        @Test func requiresAStaticallyLinkedExtension() async throws {
            // Proves Init_ext() ran: stringio is a C extension, linked into the archive by
            // --with-static-linked-ext, but only require-able once Init_ext() registers it.
            let result = try await RubyRuntime.shared.evaluate(
                "require 'stringio'; StringIO.new(\"hi\").read"
            )
            #expect(result == "hi")
        }

        @Test func requiresJSON() async throws {
            // Exercises a statically-linked C extension (json/ext) plus a bundled .rb (json.rb).
            let result = try await RubyRuntime.shared.evaluate(
                "require 'json'; JSON.parse('{\"a\":1}')['a']")
            #expect(result == "1")
        }

        @Test func requiresCSV() async throws {
            // The PRD's literal V1 success metric. Also exercises date, time, strscan,
            // forwardable, and English transitively.
            let result = try await RubyRuntime.shared.evaluate(
                "require 'csv'; CSV.parse(\"a,b\\n1,2\\n\").last.join(',')"
            )
            #expect(result == "1,2")
        }

        @Test func requiresFileUtilsAndBase64() async throws {
            _ = try await RubyRuntime.shared.evaluate("require 'fileutils'; require 'base64'")
            let result = try await RubyRuntime.shared.evaluate("Base64.strict_encode64('hi')")
            #expect(result == "aGk=")
        }

        @Test func requiresNetHTTP() async throws {
            // Locks in the sanitized rbconfig.rb fix: `require 'net/http'` used to
            // fail outright at `require 'resolv'`, because resolv.rb's top-level
            // `WINDOWS` constant always touches RbConfig (rbconfig.rb was excluded;
            // see docs/embedding-cruby.md). With a sanitized rbconfig.rb on
            // $LOAD_PATH, loading now succeeds. TLS itself is a separate capability
            // (covered by requiresNetHTTPOverTLS once OpenSSL is merged in); this
            // test only proves the loading path is unblocked.
            _ = try await RubyRuntime.shared.evaluate("require 'net/http'")
            let defined = try await RubyRuntime.shared.evaluate(
                "defined?(Net::HTTP).nil? ? 'no' : 'yes'")
            #expect(defined == "yes")
        }

        @Test func requiresLogger() async throws {
            // Extends the rbconfig fix past resolv/net-http: logger.rb requires
            // rbconfig directly (logger.rb:15), so it was broken by the same root
            // cause. Confirms the whole RbConfig surface is usable, not just the
            // slice resolv happens to touch.
            _ = try await RubyRuntime.shared.evaluate("require 'logger'")
            // Writing a log line exercises Logger.new's internals (LogDevice,
            // formatter) without needing a real IO target.
            let result = try await RubyRuntime.shared.evaluate(
                "Logger.new(File::NULL).info('x'); 'ok'"
            )
            #expect(result == "ok")
        }

        // MARK: - TLS (OpenSSL) + YAML (libyaml/psych)

        @Test func requiresOpenSSL() async throws {
            // Proves the openssl C ext loaded and libssl/libcrypto are linked into
            // libruby-static.a. SSLContext.new exercises the TLS machinery; the
            // digest is compared against the stdlib's pure-Ruby-reference Digest so
            // the assertion has no hardcoded value and returns ASCII hex (raw digest
            // bytes would contain NULs and break the C-string boundary in evaluate).
            _ = try await RubyRuntime.shared.evaluate("require 'openssl'")
            let ctx = try await RubyRuntime.shared.evaluate("OpenSSL::SSL::SSLContext.new; 'ok'")
            #expect(ctx == "ok")
            let digest = try await RubyRuntime.shared.evaluate(
                "require 'digest'; OpenSSL::Digest::SHA256.hexdigest('x') == Digest::SHA256.hexdigest('x') ? 'match' : 'mismatch'"
            )
            #expect(digest == "match")
        }

        @Test func requiresYAML() async throws {
            // Proves psych loaded and its libyaml C backend parses: `1` must come
            // back as an Integer, not a string, which only happens if libyaml is
            // actually wired in (a psych built --without-libyaml can't parse).
            let result = try await RubyRuntime.shared.evaluate(
                "require 'yaml'; YAML.safe_load(\"a: 1\\n\")['a'] == 1 ? 'yaml-ok' : 'yaml-fail'"
            )
            #expect(result == "yaml-ok")
        }

        @Test func requiresSQLite3() async throws {
            // Proves the sqlite3 ext loaded (Init_sqlite3_native registered
            // under the "sqlite3/sqlite3_native" feature name; see
            // install_sqlite3_ext_sources! in scripts/build-cruby.rb) and the
            // amalgamation it's linked against actually works: open an
            // in-memory DB, create a table, insert, and read the row back.
            let result = try await RubyRuntime.shared.evaluate(
                "require 'sqlite3'; "
                    + "db = SQLite3::Database.new(':memory:'); "
                    + "db.execute('CREATE TABLE t (name TEXT)'); "
                    + "db.execute('INSERT INTO t VALUES (?)', ['ruby']); "
                    + "db.execute('SELECT name FROM t').first.first"
            )
            #expect(result == "ruby")

            // Proves the SQLite version compiled in is the pinned amalgamation
            // (see SQLITE_VERSION_PIN in scripts/build-cruby.rb), not whatever
            // libsqlite3 the build machine's SDK happens to ship.
            let version = try await RubyRuntime.shared.evaluate("SQLite3::SQLITE_VERSION")
            #expect(version.hasPrefix("3.53"))

            // Proves -DSQLITE_ENABLE_FTS5 survived build_sqlite! and
            // merge_static_extensions!: an FTS5 virtual table only creates
            // successfully if the amalgamation was actually compiled with it.
            let fts5 = try await RubyRuntime.shared.evaluate(
                "db2 = SQLite3::Database.new(':memory:'); "
                    + "db2.execute('CREATE VIRTUAL TABLE docs USING fts5(body)'); 'fts5-ok'"
            )
            #expect(fts5 == "fts5-ok")
        }

        @Test func bundledSQLite3GemVersionMatchesTheVMsSQLite3Version() async throws {
            // The drift guard between BundledGem.all's Swift-side constant and
            // the version actually baked into the VM (SQLITE3_GEM_VERSION_PIN
            // in scripts/build-cruby.rb): a bumped pin that forgets to bump
            // BundledGem.all would otherwise ship a Gems sheet lying about the
            // version.
            let bundled = try #require(BundledGem.all.first { $0.name == "sqlite3" })
            let vmVersion = try await RubyRuntime.shared.evaluate(
                "require 'sqlite3'; SQLite3::VERSION")
            #expect(bundled.version == vmVersion)
        }

        @Test func requiresNetHTTPOverTLS() async throws {
            // Offline proxy for TLS availability: net/http loads, Net::HTTP accepts
            // use_ssl=true, and an SSLContext builds (the real TLS primitive; the
            // context is otherwise constructed lazily inside connect(), a network
            // call). A live HTTPS round-trip is a manual smoke test, not a unit test.
            let result = try await RubyRuntime.shared.evaluate(
                "require 'net/http'; require 'openssl'; "
                    + "http = Net::HTTP.new('example.com', 443); http.use_ssl = true; "
                    + "OpenSSL::SSL::SSLContext.new; http.use_ssl? ? 'tls-ok' : 'tls-fail'"
            )
            #expect(result == "tls-ok")
        }

        @Test func trustsBundledCACertificates() async throws {
            // Proves the boot wiring (RubyRuntime.configureTLS) loaded the bundled
            // Mozilla CA bundle into OpenSSL's shared default cert store, the one
            // Net::HTTP's SSLContext#set_params assigns to every HTTPS connection
            // that doesn't set its own cert_store. The first cert in cacert.pem is a
            // self-signed trusted root; verifying it against DEFAULT_CERT_STORE
            // succeeds only if the store actually contains it. An empty store (boot
            // wiring broken, or the bundle missing from the build) rejects it, so
            // this catches regressions offline: no network, no live handshake.
            let result = try await RubyRuntime.shared.evaluate(
                "require 'openssl'; "
                    + "pem = File.read(File.join($LOAD_PATH.first, 'cacert.pem')); "
                    + "cert = OpenSSL::X509::Certificate.new(pem); "
                    + "OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE.verify(cert) ? 'trusted' : 'untrusted'"
            )
            #expect(result == "trusted")
        }

        @Test func setDefaultPathsOnAFreshStoreAlsoTrustsTheBundledCACertificates() async throws {
            // Found live, testing Phase 7: httparty doesn't rely on Net::HTTP's
            // DEFAULT_CERT_STORE fallback: it builds its own
            // OpenSSL::X509::Store.new.tap(&:set_default_paths) and assigns it
            // directly as the connection's cert_store, bypassing
            // DEFAULT_CERT_STORE entirely. Guards RubyRuntime.configureTLS's
            // redefinition of X509::Store#set_default_paths, which every store
            // built that way, not just DEFAULT_CERT_STORE, now picks up.
            let result = try await RubyRuntime.shared.evaluate(
                "require 'openssl'; "
                    + "pem = File.read(File.join($LOAD_PATH.first, 'cacert.pem')); "
                    + "cert = OpenSSL::X509::Certificate.new(pem); "
                    + "store = OpenSSL::X509::Store.new; store.set_default_paths; "
                    + "store.verify(cert) ? 'trusted' : 'untrusted'"
            )
            #expect(result == "trusted")
        }

        @Test func loadPathIsExactlyTheBundledStdlibPlusAnyInstalledGems() async throws {
            // The test that would have caught a dev-machine-only pass: without this, macOS
            // could keep working via stale .build-cruby paths seeded by ruby_init_loadpath()
            // while the same code silently ships broken on device. Widened for Phase 7:
            // `installGemPaths()` now appends every installed gem's `lib/` dir after
            // stdlib, so the old "exactly one entry" assertion no longer holds. What
            // must still hold is that stdlib leads (`configureTLS()` depends on that
            // for locating `cacert.pem`) and every other entry sits under the gems root.
            let firstEntry = try await RubyRuntime.shared.evaluate("$LOAD_PATH.first")
            #expect(firstEntry.hasSuffix("/stdlib"))

            let gemsRoot = GemStore.installedGems.directoryURL.path
            let remainingCode = "$LOAD_PATH.drop(1).all? { |p| p.start_with?(\"\(gemsRoot)\") }"
            let remainingUnderGemsRoot = try await RubyRuntime.shared.evaluate(remainingCode)
            #expect(remainingUnderGemsRoot == "true")
        }

        @Test func reportsEncodingDatabaseIsLoaded() async throws {
            // Fails if Init_enc() didn't run.
            let result = try await RubyRuntime.shared.evaluate("Encoding.find('Shift_JIS').name")
            #expect(result == "Shift_JIS")
        }

        // MARK: - run(_:): STDOUT/STDERR capture (Phase 4 partial; ARGV/STDIN/ENV
        // are deferred to the App Intents slice; this covers STDOUT/STDERR + error)

        @Test func runCapturesPutsToStdout() async {
            // `puts` writes to $stdout; the captured stdout must hold it.
            let result = await RubyRuntime.shared.run("puts 'hello'")
            #expect(result.stdout == "hello\n")
            #expect(result.stderr.isEmpty)
            #expect(result.errorMessage == nil)
        }

        @Test func runCapturesStderrExplicitly() async {
            // Writing to $stderr directly is captured separately from stdout.
            let result = await RubyRuntime.shared.run("$stderr.puts 'warn'")
            #expect(result.stderr == "warn\n")
            #expect(result.stdout.isEmpty)
        }

        @Test func runReturnsLastExpressionValue() async {
            // The last expression's to_s mirrors evaluate(); a bare expression with
            // no puts has empty stdout but a meaningful result.
            let result = await RubyRuntime.shared.run("1 + 2")
            #expect(result.result == "3")
            #expect(result.stdout.isEmpty)
            #expect(!result.hasError)
        }

        @Test func runRaisesPopulateErrorAndPreservePartialStdout() async {
            // A script that prints then raises: stdout holds what printed before the
            // raise, and the error message is set: the console shows both. This is
            // the reason `run` is non-throwing (evaluate's throws path would drop the
            // partial stdout).
            let result = await RubyRuntime.shared.run("puts 'before'; raise 'boom'")
            #expect(result.stdout == "before\n")
            #expect(result.hasError)
            #expect(result.errorMessage == "boom")
        }

        @Test func runPopulatesBacktraceOnRaise() async {
            // A raise from inside a method: the backtrace holds at least the
            // method's frame and the top-level call site, in that order (innermost
            // first, matching Exception#backtrace).
            let result = await RubyRuntime.shared.run("def foo\n  raise 'boom'\nend\nfoo")
            #expect(result.hasError)
            #expect(!result.backtrace.isEmpty)
            #expect(result.backtrace.first?.contains("foo") == true)
        }

        @Test func runLeavesBacktraceEmptyOnACleanRun() async {
            let result = await RubyRuntime.shared.run("1 + 2")
            #expect(!result.hasError)
            #expect(result.backtrace.isEmpty)
        }

        @Test func backtraceDoesNotLeakFromAPreviousRun() async {
            // Guards the read-order choice in `run`: the backtrace must be read
            // right after the failing eval, before any later eval (e.g. reading
            // $cap_out.string) can overwrite $rc_last_error. A raise followed by a
            // clean run must leave the clean run's backtrace empty.
            _ = await RubyRuntime.shared.run("raise 'boom'")
            let result = await RubyRuntime.shared.run("1 + 1")
            #expect(!result.hasError)
            #expect(result.backtrace.isEmpty)
        }

        @Test func runMeasuresTheUserCodeEvalDuration() async {
            // A loose assertion on purpose: a tight bound on either side
            // would be flaky on shared CI. `1_000.times { }` just needs to
            // take a measurable, non-zero amount of time; the point is that
            // `duration`/`finishedAt` get populated by a real run at all.
            let result = await RubyRuntime.shared.run("1_000.times { }")
            #expect(!result.hasError)
            #expect(result.duration > 0)
            #expect(result.duration < 60)
            #expect(abs(result.finishedAt.timeIntervalSinceNow) < 10)
        }

        @Test func runRestoresStdoutAfterRunning() async {
            // Capture must restore $stdout/$stderr afterward, or a later evaluate
            // would silently write to a StringIO and return empty. Drives a `run`,
            // then a plain `evaluate` whose puts should reach the real stdout (the
            // returned result proves the eval ran; the point is it didn't error).
            _ = await RubyRuntime.shared.run("puts 'captured'")
            // After run, $stdout must be the real STDOUT again (not a StringIO),
            // otherwise this evaluate writes into the stale capture buffer.
            let restored = try? await RubyRuntime.shared.evaluate(
                "$stdout == STDOUT ? 'restored' : 'still-captured'"
            )
            #expect(restored == "restored")
        }

        // MARK: - Top-level jumps (return/break/...): the shim's non-RAISE tag path
        //
        // Guards rubycuts_shim.c's rc_error_message_for_state: rb_eval_string_protect
        // surfaces a top-level `return` as TAG_RETURN (not TAG_RAISE), and ec->errinfo
        // is internal throw data, not a Ruby object. The old shim called
        // rb_obj_as_string on it and crashed the process (SIGSEGV inside rb_longjmp),
        // reproduced by running `return {}` in the console. The shim now synthesizes a
        // message for non-RAISE tags. Kept in this serialized suite (not a separate
        // one) so all VM-driving tests share one serial execution contract.

        @Test func topLevelReturnDoesNotCrash() async {
            let result = await RubyRuntime.shared.run("return {}")
            #expect(result.hasError)
            // Matches MRI's LocalJumpError wording for a top-level return.
            #expect(result.errorMessage == "unexpected return")
            #expect(result.stdout.isEmpty)
        }

        @Test func topLevelReturnLeavesBacktraceEmpty() async {
            // Guards the shim's non-RAISE-tag branch: a top-level return has no
            // exception object, so $rc_last_error must be Qnil, not a stale
            // exception from an earlier raise. Self-contained (raises first) so
            // the guard doesn't depend on source-order relative to other tests.
            _ = await RubyRuntime.shared.run("raise 'boom'")
            let result = await RubyRuntime.shared.run("return {}")
            #expect(result.hasError)
            #expect(result.backtrace.isEmpty)
        }

        @Test func topLevelBreakReportsAnErrorWithoutCrashing() async {
            // A bare `break` at the top level is a syntax error (a real TAG_RAISE
            // exception), not a TAG_BREAK jump. So this exercises the shim's normal
            // exception-message path, not the synthesized-message path. It must not
            // crash and must report some error.
            let result = await RubyRuntime.shared.run("break")
            #expect(result.hasError)
        }

        @Test func evaluateSurvivesTopLevelReturn() async {
            // The fix is in the shim, so evaluate (not just run) is protected too: a
            // top-level return throws RubyError rather than crashing the runner.
            await #expect(throws: RubyError.self) {
                _ = try await RubyRuntime.shared.evaluate("return 1")
            }
        }

        @Test func vmIsUsableAfterATopLevelReturn() async throws {
            // The throw data must be cleared so the VM is clean for later evals: a
            // corrupted errinfo would surface as a crash or stale error next time.
            _ = await RubyRuntime.shared.run("return {}")
            let ok = try await RubyRuntime.shared.evaluate("1 + 1")
            #expect(ok == "2")
        }

        // MARK: - exit!/abort hardening
        //
        // Guards RubyRuntime.hardenProcessExit: exit!/abort call the real C exit()
        // directly, bypassing rb_eval_string_protect's catch, so a bare `exit!`
        // would kill the host app. Boot overrides Kernel#exit!/#abort to raise a
        // catchable SystemExit instead, so the run fails rather than the app dying.

        @Test func exitBangDoesNotKillTheHost() async {
            // Before the override this terminated the test runner. Now it surfaces as
            // a SystemExit error and the process keeps running.
            let result = await RubyRuntime.shared.run("exit!")
            #expect(result.hasError)
            #expect(result.errorMessage == "SystemExit")
        }

        @Test func exitBangWithStatusIsCatchable() async {
            let result = await RubyRuntime.shared.run("exit!(2)")
            #expect(result.hasError)
            #expect(result.errorMessage == "SystemExit")
        }

        @Test func abortDoesNotKillTheHost() async {
            // abort routes through exit! internally; the override makes it raise too.
            let result = await RubyRuntime.shared.run("abort")
            #expect(result.hasError)
            #expect(result.errorMessage == "SystemExit")
        }

        @Test func plainExitIsAlreadySafe() async {
            // Regression guard: plain `exit` raises SystemExit natively (no override
            // needed) and was always caught. The message is MRI's "exit" string, not
            // "SystemExit" like the exit! override produces. The point here is just
            // that it's caught and doesn't kill the host.
            let result = await RubyRuntime.shared.run("exit")
            #expect(result.hasError)
        }

        @Test func vmIsUsableAfterAnExitBang() async throws {
            _ = await RubyRuntime.shared.run("exit!")
            let ok = try await RubyRuntime.shared.evaluate("1 + 1")
            #expect(ok == "2")
        }

        // MARK: - "Run Ruby Script" App Intent integration (output-side, Phase 5)
        //
        // The one VM-driving contract for the App Intents slice: seed a temp-dir
        // store, resolve a stored script through the ``ScriptEntity`` picker path
        // (entity -> ``Script`` -> ``ScriptStore/loadSource(of:timeout:)``), run it via
        // ``runToOutput(_:)``, and confirm the captured `$stdout` flows out to the
        // intent's return value. Kept in this `.serialized` suite, not a second
        // one, so all VM-driving tests share one serial execution contract (the
        // cross-suite double-load hazard the suite header warns about). The pure
        // ``output(from:)`` decision is covered separately in `IntentOutputTests`.

        @Test func runRubyScriptIntentFlowsStdoutOut() async throws {
            let dir = FileManager.default.temporaryDirectory
                .appending(component: "RubyCutsTests-\(UUID().uuidString)")
            let store = ScriptStore(directoryURL: dir)
            try store.ensureDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }

            let script = try store.create(name: "intent-smoke", source: "puts 'from-script'")
            let entity = ScriptEntity(script)

            // The intent's resolve path: ``ScriptEntity/script(in:)`` ->
            // ``ScriptStore/loadSource(of:timeout:)`` -> ``runToOutput(_:)``.
            let resolved = try #require(entity.script(in: store))
            let source = try await store.loadSource(of: resolved)
            let output = try await runToOutput(source)

            #expect(output == "from-script\n")
        }

        @Test func runRubyScriptIntentFailsOnRaise() async throws {
            // Same path as above but the script raises: ``runToOutput`` throws a
            // ``RubyRunError`` carrying the Ruby message, which the intent surfaces
            // in Shortcuts. Proves the error contract, not just the happy path.
            let dir = FileManager.default.temporaryDirectory
                .appending(component: "RubyCutsTests-\(UUID().uuidString)")
            let store = ScriptStore(directoryURL: dir)
            try store.ensureDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }

            let script = try store.create(name: "intent-fail", source: "raise 'boom'")
            let entity = ScriptEntity(script)

            let resolved = try #require(entity.script(in: store))
            let source = try await store.loadSource(of: resolved)

            let error = try await #require(throws: RubyRunError.self) {
                try await runToOutput(source)
            }

            // The combined message leads with the exception's `to_s`, followed by
            // its backtrace (see ``combinedMessage(_:)`` in RubyIntents.swift).
            #expect(error.message.hasPrefix("boom\n"))
        }

        // MARK: - run(_:input:): ARGV / STDIN / ENV plumbing (Phase 4 input side)
        //
        // The VM-driving contract for the input slice: a non-empty ``RunInput``
        // reaches the script as `ARGV` / `$stdin` / `ENV`, an empty one runs today's
        // plain capture path, and the teardown restores prior state so a Shortcut
        // run's env never bleeds into a later console `evaluate`. Same `.serialized`
        // suite as every other VM-driving test: the single interpreter is
        // non-thread-safe, so all VM work shares one serial execution contract.

        @Test func runReceivesArgv() async {
            let result = await RubyRuntime.shared.run(
                "puts ARGV[0]", input: RunInput(argv: ["hello"]))
            #expect(result.stdout == "hello\n")
            #expect(!result.hasError)
        }

        @Test func runReceivesStdin() async {
            let result = await RubyRuntime.shared.run(
                "puts $stdin.read", input: RunInput(stdin: "data"))
            #expect(result.stdout == "data\n")
            #expect(!result.hasError)
        }

        @Test func runReceivesEnv() async {
            let result = await RubyRuntime.shared.run(
                "puts ENV['MYKEY']", input: RunInput(env: [("MYKEY", "val")])
            )
            #expect(result.stdout == "val\n")
            #expect(!result.hasError)
        }

        @Test func runReceivesArgvStdinAndEnvTogether() async {
            // All three channels coexist: ARGV joins, $stdin reads, ENV looks up.
            let input = RunInput(argv: ["a", "b"], stdin: "data", env: [("K", "v")])
            let result = await RubyRuntime.shared.run(
                "puts ARGV.join(','); puts $stdin.read; puts ENV['K']", input: input
            )
            #expect(result.stdout == "a,b\ndata\nv\n")
            #expect(!result.hasError)
        }

        @Test func runWithEmptyInputLeavesArgvEmpty() async {
            // The opt-in path: an empty RunInput runs the plain capture (no
            // ARGV setup), so ARGV is its default empty array.
            let result = await RubyRuntime.shared.run("puts ARGV.length", input: .empty)
            #expect(result.stdout == "0\n")
            #expect(!result.hasError)
        }

        @Test func envRunDoesNotLeakIntoLaterEvaluations() async throws {
            // Teardown must restore each ENV key to its prior state (absent here),
            // so a value a Shortcut run set doesn't bleed into the console or the
            // next run. `ENV['RC_X']` returns nil after teardown -> `nil.to_s` == "".
            _ = await RubyRuntime.shared.run(
                "puts ENV['RC_X']", input: RunInput(env: [("RC_X", "secret")])
            )
            let leaked = try await RubyRuntime.shared.evaluate("ENV['RC_X'].to_s")
            #expect(leaked == "")
        }

        @Test func envRunRestoresAPreviouslyPresentValue() async throws {
            // When the key already had a value before the run, teardown restores
            // that prior value rather than deleting the key. Set a baseline in the
            // VM, run with an input that overwrites it, then confirm the baseline
            // survived.
            _ = try await RubyRuntime.shared.evaluate("ENV['RC_Y'] = 'original'")
            _ = await RubyRuntime.shared.run(
                "puts ENV['RC_Y']", input: RunInput(env: [("RC_Y", "overwritten")])
            )
            let restored = try await RubyRuntime.shared.evaluate("ENV['RC_Y']")
            #expect(restored == "original")
            // Clean up the baseline so no test state leaks forward.
            _ = try? await RubyRuntime.shared.evaluate("ENV.delete('RC_Y')")
        }

        // Duplicate ENV keys: the last value is what the script sees, and
        // teardown restores the state from before the run, not the first
        // supplied value. Each case also runs a script that raises, since
        // teardown has to hold on that path too.

        @Test(arguments: ["puts ENV['RC_DUP']", "raise 'boom'"])
        func duplicateEnvKeyPreviouslyAbsentIsRemovedAfterTheRun(script: String) async throws {
            _ = try await RubyRuntime.shared.evaluate("ENV.delete('RC_DUP'); nil")
            let result = await RubyRuntime.shared.run(
                script, input: RunInput(env: [("RC_DUP", "first"), ("RC_DUP", "second")])
            )
            if script.hasPrefix("raise") {
                #expect(result.hasError)
            } else {
                #expect(result.stdout == "second\n")
            }
            let after = try await RubyRuntime.shared.evaluate("ENV['RC_DUP'].inspect")
            #expect(after == "nil")
        }

        @Test(arguments: ["puts ENV['RC_DUP']", "raise 'boom'"])
        func duplicateEnvKeyPreviouslyPresentIsRestoredAfterTheRun(script: String) async throws {
            _ = try await RubyRuntime.shared.evaluate("ENV['RC_DUP'] = 'original'")
            let result = await RubyRuntime.shared.run(
                script, input: RunInput(env: [("RC_DUP", "first"), ("RC_DUP", "second")])
            )
            if script.hasPrefix("raise") {
                #expect(result.hasError)
            } else {
                #expect(result.stdout == "second\n")
            }
            let after = try await RubyRuntime.shared.evaluate("ENV['RC_DUP']")
            #expect(after == "original")
            _ = try? await RubyRuntime.shared.evaluate("ENV.delete('RC_DUP')")
        }

        // Invalid input: rejected before any channel is touched, so the
        // script never runs and nothing from the input is left behind.

        @Test func validArgvWithAnInvalidEnvValueFailsWithoutRunningOrLeaking() async throws {
            let argvBefore = try await RubyRuntime.shared.evaluate("ARGV.inspect")
            _ = try await RubyRuntime.shared.evaluate(
                "$rc_bad_input_ran = nil; ENV.delete('RC_OK'); nil")

            let result = await RubyRuntime.shared.run(
                "$rc_bad_input_ran = true; ARGV.first",
                input: RunInput(argv: ["hello"], env: [("RC_OK", "fine"), ("RC_BAD", "a\0b")])
            )

            #expect(result.errorMessage?.contains("RC_BAD") == true)
            #expect(result.result.isEmpty)
            #expect(try await RubyRuntime.shared.evaluate("$rc_bad_input_ran.inspect") == "nil")
            #expect(try await RubyRuntime.shared.evaluate("ARGV.inspect") == argvBefore)
            #expect(try await RubyRuntime.shared.evaluate("ENV['RC_OK'].inspect") == "nil")
            #expect(try await RubyRuntime.shared.evaluate("ENV['RC_BAD'].inspect") == "nil")

            // And the VM is fine for the next run.
            let next = await RubyRuntime.shared.run("ARGV.first", input: RunInput(argv: ["x"]))
            #expect(next.result == "x")
            #expect(!next.hasError)
        }

        @Test(arguments: [
            ("", "v"),
            ("A=B", "v"),
            ("A\0B", "v"),
        ])
        func envKeysRubyCannotSetAreRejectedUpFront(key: String, value: String) {
            let input = RunInput(env: [(key, value)])
            #expect(input.validationError != nil)
        }

        @Test func ordinaryInputPassesValidation() {
            let input = RunInput(
                argv: ["a\0b"], stdin: "line\n\0", env: [("KEY", "value with = sign")])
            #expect(input.validationError == nil)
        }

        // MARK: - Conversions at the C boundary
        //
        // Guards rubycuts_shim.c's rubycuts_eval and rc_error_message_for_state:
        // turning a result or an exception into a string runs user Ruby (a
        // redefined `to_s`) and used to happen outside rb_protect, so a raise
        // there longjmp'd across the Swift frames and took down the process,
        // and StringValueCStr raised on any embedded NUL. Each case runs as an
        // exit test, in its own child process, so a regression fails that one
        // test instead of crashing the whole suite. The child exits nonzero
        // through `precondition` when an expectation doesn't hold, and each
        // case also checks that a normal run still works afterwards.

        @Test func aResultWhoseToSRaisesIsReportedAsAnError() async {
            await #expect(processExitsWith: .success) {
                let result = await RubyRuntime.shared.run(
                    "Object.new.tap { |o| def o.to_s; raise 'conversion failed'; end }"
                )
                precondition(result.errorMessage == "conversion failed", "\(result)")
                let next = await RubyRuntime.shared.run("1 + 1")
                precondition(next.result == "2" && !next.hasError, "\(next)")
            }
        }

        @Test func aResultWithAnEmbeddedNulArrivesWhole() async {
            await #expect(processExitsWith: .success) {
                let result = try await RubyRuntime.shared.evaluate(#""a\0b""#)
                precondition(result == "a\u{0}b", result.debugDescription)
                let next = await RubyRuntime.shared.run("1 + 1")
                precondition(next.result == "2" && !next.hasError, "\(next)")
            }
        }

        @Test func printedOutputWithAnEmbeddedNulArrivesWhole() async {
            await #expect(processExitsWith: .success) {
                let result = await RubyRuntime.shared.run(#"print "a\0b"; nil"#)
                precondition(!result.hasError, "\(result)")
                precondition(result.stdout == "a\u{0}b", result.stdout.debugDescription)
                let next = await RubyRuntime.shared.run("1 + 1")
                precondition(next.result == "2" && !next.hasError, "\(next)")
            }
        }

        @Test func anExceptionWhoseToSRaisesFallsBackToItsClassName() async {
            await #expect(processExitsWith: .success) {
                let result = await RubyRuntime.shared.run(
                    "class RCUnprintableError < StandardError; def to_s; raise 'nope'; end; end; "
                        + "raise RCUnprintableError"
                )
                precondition(
                    result.errorMessage?.hasPrefix("RCUnprintableError") == true, "\(result)")
                let next = await RubyRuntime.shared.run("1 + 1")
                precondition(next.result == "2" && !next.hasError, "\(next)")
            }
        }

        @Test func anExceptionMessageWithAnEmbeddedNulArrivesWhole() async {
            await #expect(processExitsWith: .success) {
                let result = await RubyRuntime.shared.run(#"raise "a\0b""#)
                precondition(result.errorMessage == "a\u{0}b", "\(result)")
                let next = await RubyRuntime.shared.run("1 + 1")
                precondition(next.result == "2" && !next.hasError, "\(next)")
            }
        }

        // MARK: - Script run cancellation (Phase 8, Wave B)
        //
        // These work *because* `RubyRuntime` runs on its own dedicated
        // thread: the test's own task isn't blocked while a run occupies the
        // VM thread, so cancelling that task reaches in out of band. Guards
        // `rubycuts_shim.c`'s per-run cancellation state and event hook
        // (RUBY_EVENT_LINE | CALL | B_CALL) and
        // `RubyRuntime.runCancellable(_:input:)`.

        @Test func cancelsALongRunningLoop() async throws {
            // The load-bearing test: if rb_raise from inside an event hook
            // were unsafe against rb_eval_string_protect's longjmp, this is
            // where it would fail or crash rather than returning cleanly.
            let runTask = Task { await RubyRuntime.shared.runCancellable("i = 0; loop { i += 1 }") }
            try await Task.sleep(for: .milliseconds(200))
            runTask.cancel()
            let result = await runTask.value
            #expect(result.wasCancelled)
        }

        @Test func cancelKeepsOutputPrintedBeforeTheStop() async throws {
            let runTask = Task {
                await RubyRuntime.shared.runCancellable("puts 'before'; loop { }")
            }
            try await Task.sleep(for: .milliseconds(200))
            runTask.cancel()
            let result = await runTask.value
            #expect(result.wasCancelled)
            #expect(result.stdout.contains("before"))
        }

        @Test func cancelInterruptsAnEmptyBodiedIteration() async throws {
            // RUBY_EVENT_LINE alone never fires inside `{ }`'s empty body:
            // there's no statement to sit between. B_CALL (the block's own
            // entry) is what the hook catches instead, so this is the case
            // that justifies including it alongside LINE/CALL.
            let runTask = Task {
                await RubyRuntime.shared.runCancellable("10_000_000_000.times { }")
            }
            try await Task.sleep(for: .milliseconds(200))
            runTask.cancel()
            let result = await runTask.value
            #expect(result.wasCancelled)
        }

        @Test func aCleanRunIsNotReportedAsCancelled() async {
            let result = await RubyRuntime.shared.runCancellable("1 + 1")
            #expect(!result.wasCancelled)
        }

        @Test func cancellationDoesNotLeakIntoTheNextRun() async throws {
            // A cancellation belongs to the run it was requested for, so a
            // later, unrelated run must not be reported as cancelled too.
            let runTask = Task { await RubyRuntime.shared.runCancellable("loop { }") }
            try await Task.sleep(for: .milliseconds(200))
            runTask.cancel()
            _ = await runTask.value

            let result = await RubyRuntime.shared.runCancellable("2 + 2")
            #expect(result.result == "4")
            #expect(!result.wasCancelled)
        }

        @Test func aLateCancellationDoesNotAffectTheNextRun() async {
            // Cancelling a task whose run already finished must be a no-op.
            // With the old single global flag, this request would sit there
            // and interrupt whichever run came next.
            let finishedTask = Task { await RubyRuntime.shared.runCancellable("1 + 1") }
            let finished = await finishedTask.value
            #expect(!finished.wasCancelled)
            finishedTask.cancel()

            let next = await RubyRuntime.shared.runCancellable("i = 0; 10_000.times { i += 1 }; i")
            #expect(next.result == "10000")
            #expect(!next.wasCancelled)
        }

        @Test func cancellingAQueuedRunLeavesTheActiveRunAlone() async throws {
            // Run A holds the VM thread until the test releases it, through a
            // file barrier (nothing else can eval while A runs, so a Ruby
            // global couldn't release it). Run B queues behind A and gets
            // cancelled. A must finish normally, and B must report cancelled
            // without ever having evaluated its script.
            let barrier = FileManager.default.temporaryDirectory
                .appending(component: "rubycuts-cancel-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: barrier, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: barrier) }
            let started = barrier.appending(component: "started").path
            let release = barrier.appending(component: "release").path

            _ = try await RubyRuntime.shared.evaluate("$rc_queued_b_ran = nil")

            let runA = Task {
                await RubyRuntime.shared.runCancellable(
                    "File.write('\(started)', ''); "
                        + "sleep 0.01 until File.exist?('\(release)'); 'a-finished'"
                )
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while !FileManager.default.fileExists(atPath: started) {
                try #require(ContinuousClock.now < deadline, "run A never started")
                try await Task.sleep(for: .milliseconds(10))
            }

            let runB = Task {
                await RubyRuntime.shared.runCancellable("$rc_queued_b_ran = true; 'b-finished'")
            }
            try await Task.sleep(for: .milliseconds(50))
            runB.cancel()
            // Give a misrouted cancellation time to hit A's polling loop before
            // A is released, so the test fails if B's request reaches A.
            try await Task.sleep(for: .milliseconds(100))
            FileManager.default.createFile(atPath: release, contents: nil)

            let resultA = await runA.value
            #expect(resultA.result == "a-finished")
            #expect(!resultA.hasError)
            #expect(!resultA.wasCancelled)

            let resultB = await runB.value
            #expect(resultB.wasCancelled)
            #expect(resultB.result.isEmpty)

            let bRan = try await RubyRuntime.shared.evaluate("$rc_queued_b_ran.inspect")
            #expect(bRan == "nil")
        }

    }
}
