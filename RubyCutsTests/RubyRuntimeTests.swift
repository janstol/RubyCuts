import Foundation
import Testing

@testable import RubyCuts

// Every test drives the same embedded CRuby VM through `RubyRuntime.shared`,
// which is a single non-thread-safe interpreter. Swift Testing runs tests
// concurrently by default; left that way, two tests racing through
// `require 'net/http'` -> `require 'resolv'` -> `require 'rbconfig'` can
// double-load resolv.rb and leave RbConfig undefined for the loser (seen on
// the iOS Simulator; macOS scheduling happened not to trip it). `.serialized`
// runs the suite's tests one at a time, matching the runtime's single-threaded
// contract. The app itself is unaffected -- it only touches the VM serially
// from the main actor, one user action at a time.
@MainActor
@Suite(.serialized)
struct RubyRuntimeTests {

    // MARK: - Boot parity with a normal `ruby` interpreter

    @Test func rbConfigIsDefinedAtBoot() throws {
        // Guards `RubyRuntime.loadRbConfig()` (run from `bootIfNeeded`): a normal
        // `ruby` interpreter loads rbconfig.rb during startup so RbConfig is
        // defined before any code runs, but our minimal `rubycuts_init` boot
        // does not. Without loadRbConfig(), stdlib files that reference RbConfig
        // without an explicit `require 'rbconfig'` (resolv.rb's `WINDOWS`
        // constant, fileutils.rb) raise `NameError: uninitialized constant
        // RbConfig` in a fresh process -- which is exactly what the real app
        // hit doing `require 'net/http'`. Placed first in this `.serialized`
        // suite so, in its source-order run, only boot has had a chance to load
        // rbconfig; if boot stops loading it, this fails before later tests
        // (logger, fileutils) mask the regression by loading rbconfig themselves.
        let defined = try RubyRuntime.shared.evaluate("defined?(RbConfig)")
        #expect(defined == "constant")
    }

    @Test func addsIntegers() throws {
        #expect(try RubyRuntime.shared.evaluate("1 + 1") == "2")
    }

    @Test func upcasesAString() throws {
        #expect(try RubyRuntime.shared.evaluate("\"hello\".upcase") == "HELLO")
    }

    @Test func reportsRubyVersion() throws {
        let version = try RubyRuntime.shared.evaluate("RUBY_VERSION")
        #expect(version.hasPrefix("3.4"))
    }

    @Test func throwsOnSyntaxError() {
        do {
            _ = try RubyRuntime.shared.evaluate("def broken(")
            Issue.record("expected evaluate to throw on a syntax error")
        } catch RubyError.evaluationFailed(let message) {
            #expect(!message.isEmpty)
        } catch {
            Issue.record("expected RubyError, got \(error)")
        }
    }

    @Test func throwsOnRaise() {
        do {
            _ = try RubyRuntime.shared.evaluate("raise 'boom'")
            Issue.record("expected evaluate to throw when Ruby raises")
        } catch RubyError.evaluationFailed(let message) {
            #expect(!message.isEmpty)
        } catch {
            Issue.record("expected RubyError, got \(error)")
        }
    }

    @Test func vmStatePersistsAcrossEvaluations() throws {
        _ = try RubyRuntime.shared.evaluate("$rubycuts_test_counter = 41")
        let result = try RubyRuntime.shared.evaluate("$rubycuts_test_counter += 1")
        #expect(result == "42")
    }

    // MARK: - Boot completion (rubycuts_init via ruby_options, not bare ruby_init)

    @Test func requiresAStaticallyLinkedExtension() throws {
        // Proves Init_ext() ran: stringio is a C extension, linked into the archive by
        // --with-static-linked-ext, but only require-able once Init_ext() registers it.
        let result = try RubyRuntime.shared.evaluate(
            "require 'stringio'; StringIO.new(\"hi\").read"
        )
        #expect(result == "hi")
    }

    @Test func requiresJSON() throws {
        // Exercises a statically-linked C extension (json/ext) plus a bundled .rb (json.rb).
        let result = try RubyRuntime.shared.evaluate("require 'json'; JSON.parse('{\"a\":1}')['a']")
        #expect(result == "1")
    }

    @Test func requiresCSV() throws {
        // The PRD's literal V1 success metric. Also exercises date, time, strscan,
        // forwardable, and English transitively.
        let result = try RubyRuntime.shared.evaluate(
            "require 'csv'; CSV.parse(\"a,b\\n1,2\\n\").last.join(',')"
        )
        #expect(result == "1,2")
    }

    @Test func requiresFileUtilsAndBase64() throws {
        _ = try RubyRuntime.shared.evaluate("require 'fileutils'; require 'base64'")
        let result = try RubyRuntime.shared.evaluate("Base64.strict_encode64('hi')")
        #expect(result == "aGk=")
    }

    @Test func requiresNetHTTP() throws {
        // Locks in the sanitized rbconfig.rb fix: `require 'net/http'` used to
        // fail outright at `require 'resolv'`, because resolv.rb's top-level
        // `WINDOWS` constant always touches RbConfig (rbconfig.rb was excluded --
        // see docs/embedding-cruby.md). With a sanitized rbconfig.rb on
        // $LOAD_PATH, loading now succeeds. TLS itself is a separate capability
        // (covered by requiresNetHTTPOverTLS once OpenSSL is merged in); this
        // test only proves the loading path is unblocked.
        _ = try RubyRuntime.shared.evaluate("require 'net/http'")
        let defined = try RubyRuntime.shared.evaluate("defined?(Net::HTTP).nil? ? 'no' : 'yes'")
        #expect(defined == "yes")
    }

    @Test func requiresLogger() throws {
        // Extends the rbconfig fix past resolv/net-http: logger.rb requires
        // rbconfig directly (logger.rb:15), so it was broken by the same root
        // cause. Confirms the whole RbConfig surface is usable, not just the
        // slice resolv happens to touch.
        _ = try RubyRuntime.shared.evaluate("require 'logger'")
        // Writing a log line exercises Logger.new's internals (LogDevice,
        // formatter) without needing a real IO target.
        let result = try RubyRuntime.shared.evaluate(
            "Logger.new(File::NULL).info('x'); 'ok'"
        )
        #expect(result == "ok")
    }

    // MARK: - TLS (OpenSSL) + YAML (libyaml/psych)

    @Test func requiresOpenSSL() throws {
        // Proves the openssl C ext loaded and libssl/libcrypto are linked into
        // libruby-static.a. SSLContext.new exercises the TLS machinery; the
        // digest is compared against the stdlib's pure-Ruby-reference Digest so
        // the assertion has no hardcoded value and returns ASCII hex (raw digest
        // bytes would contain NULs and break the C-string boundary in evaluate).
        _ = try RubyRuntime.shared.evaluate("require 'openssl'")
        let ctx = try RubyRuntime.shared.evaluate("OpenSSL::SSL::SSLContext.new; 'ok'")
        #expect(ctx == "ok")
        let digest = try RubyRuntime.shared.evaluate(
            "require 'digest'; OpenSSL::Digest::SHA256.hexdigest('x') == Digest::SHA256.hexdigest('x') ? 'match' : 'mismatch'"
        )
        #expect(digest == "match")
    }

    @Test func requiresYAML() throws {
        // Proves psych loaded and its libyaml C backend parses: `1` must come
        // back as an Integer, not a string, which only happens if libyaml is
        // actually wired in (a psych built --without-libyaml can't parse).
        let result = try RubyRuntime.shared.evaluate(
            "require 'yaml'; YAML.safe_load(\"a: 1\\n\")['a'] == 1 ? 'yaml-ok' : 'yaml-fail'"
        )
        #expect(result == "yaml-ok")
    }

    @Test func requiresSQLite3() throws {
        // Proves the sqlite3 ext loaded (Init_sqlite3_native registered
        // under the "sqlite3/sqlite3_native" feature name -- see
        // install_sqlite3_ext_sources! in scripts/build-cruby.rb) and the
        // amalgamation it's linked against actually works: open an
        // in-memory DB, create a table, insert, and read the row back.
        let result = try RubyRuntime.shared.evaluate(
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
        let version = try RubyRuntime.shared.evaluate("SQLite3::SQLITE_VERSION")
        #expect(version.hasPrefix("3.53"))

        // Proves -DSQLITE_ENABLE_FTS5 survived build_sqlite! and
        // merge_static_extensions! -- an FTS5 virtual table only creates
        // successfully if the amalgamation was actually compiled with it.
        let fts5 = try RubyRuntime.shared.evaluate(
            "db2 = SQLite3::Database.new(':memory:'); "
                + "db2.execute('CREATE VIRTUAL TABLE docs USING fts5(body)'); 'fts5-ok'"
        )
        #expect(fts5 == "fts5-ok")
    }

    @Test func bundledSQLite3GemVersionMatchesTheVMsSQLite3Version() throws {
        // The drift guard between BundledGem.all's Swift-side constant and
        // the version actually baked into the VM (SQLITE3_GEM_VERSION_PIN
        // in scripts/build-cruby.rb) -- a bumped pin that forgets to bump
        // BundledGem.all would otherwise ship a Gems sheet lying about the
        // version.
        let bundled = try #require(BundledGem.all.first { $0.name == "sqlite3" })
        let vmVersion = try RubyRuntime.shared.evaluate("require 'sqlite3'; SQLite3::VERSION")
        #expect(bundled.version == vmVersion)
    }

    @Test func requiresNetHTTPOverTLS() throws {
        // Offline proxy for TLS availability: net/http loads, Net::HTTP accepts
        // use_ssl=true, and an SSLContext builds (the real TLS primitive -- the
        // context is otherwise constructed lazily inside connect(), a network
        // call). A live HTTPS round-trip is a manual smoke test, not a unit test.
        let result = try RubyRuntime.shared.evaluate(
            "require 'net/http'; require 'openssl'; "
                + "http = Net::HTTP.new('example.com', 443); http.use_ssl = true; "
                + "OpenSSL::SSL::SSLContext.new; http.use_ssl? ? 'tls-ok' : 'tls-fail'"
        )
        #expect(result == "tls-ok")
    }

    @Test func trustsBundledCACertificates() throws {
        // Proves the boot wiring (RubyRuntime.configureTLS) loaded the bundled
        // Mozilla CA bundle into OpenSSL's shared default cert store -- the one
        // Net::HTTP's SSLContext#set_params assigns to every HTTPS connection
        // that doesn't set its own cert_store. The first cert in cacert.pem is a
        // self-signed trusted root; verifying it against DEFAULT_CERT_STORE
        // succeeds only if the store actually contains it. An empty store (boot
        // wiring broken, or the bundle missing from the build) rejects it, so
        // this catches regressions offline -- no network, no live handshake.
        let result = try RubyRuntime.shared.evaluate(
            "require 'openssl'; "
                + "pem = File.read(File.join($LOAD_PATH.first, 'cacert.pem')); "
                + "cert = OpenSSL::X509::Certificate.new(pem); "
                + "OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE.verify(cert) ? 'trusted' : 'untrusted'"
        )
        #expect(result == "trusted")
    }

    @Test func setDefaultPathsOnAFreshStoreAlsoTrustsTheBundledCACertificates() throws {
        // Found live, testing Phase 7: httparty doesn't rely on Net::HTTP's
        // DEFAULT_CERT_STORE fallback -- it builds its own
        // OpenSSL::X509::Store.new.tap(&:set_default_paths) and assigns it
        // directly as the connection's cert_store, bypassing
        // DEFAULT_CERT_STORE entirely. Guards RubyRuntime.configureTLS's
        // redefinition of X509::Store#set_default_paths, which every store
        // built that way -- not just DEFAULT_CERT_STORE -- now picks up.
        let result = try RubyRuntime.shared.evaluate(
            "require 'openssl'; "
                + "pem = File.read(File.join($LOAD_PATH.first, 'cacert.pem')); "
                + "cert = OpenSSL::X509::Certificate.new(pem); "
                + "store = OpenSSL::X509::Store.new; store.set_default_paths; "
                + "store.verify(cert) ? 'trusted' : 'untrusted'"
        )
        #expect(result == "trusted")
    }

    @Test func loadPathIsExactlyTheBundledStdlibPlusAnyInstalledGems() throws {
        // The test that would have caught a dev-machine-only pass: without this, macOS
        // could keep working via stale .build-cruby paths seeded by ruby_init_loadpath()
        // while the same code silently ships broken on device. Widened for Phase 7:
        // `installGemPaths()` now appends every installed gem's `lib/` dir after
        // stdlib, so the old "exactly one entry" assertion no longer holds -- what
        // must still hold is that stdlib leads (`configureTLS()` depends on that
        // for locating `cacert.pem`) and every other entry sits under the gems root.
        let firstEntry = try RubyRuntime.shared.evaluate("$LOAD_PATH.first")
        #expect(firstEntry.hasSuffix("/stdlib"))

        let gemsRoot = GemStore.installedGems.directoryURL.path
        let remainingCode = "$LOAD_PATH.drop(1).all? { |p| p.start_with?(\"\(gemsRoot)\") }"
        let remainingUnderGemsRoot = try RubyRuntime.shared.evaluate(remainingCode)
        #expect(remainingUnderGemsRoot == "true")
    }

    @Test func reportsEncodingDatabaseIsLoaded() throws {
        // Fails if Init_enc() didn't run.
        let result = try RubyRuntime.shared.evaluate("Encoding.find('Shift_JIS').name")
        #expect(result == "Shift_JIS")
    }

    // MARK: - run(_:): STDOUT/STDERR capture (Phase 4 partial -- ARGV/STDIN/ENV
    // are deferred to the App Intents slice; this covers STDOUT/STDERR + error)

    @Test func runCapturesPutsToStdout() {
        // `puts` writes to $stdout; the captured stdout must hold it.
        let result = RubyRuntime.shared.run("puts 'hello'")
        #expect(result.stdout == "hello\n")
        #expect(result.stderr.isEmpty)
        #expect(result.errorMessage == nil)
    }

    @Test func runCapturesStderrExplicitly() {
        // Writing to $stderr directly is captured separately from stdout.
        let result = RubyRuntime.shared.run("$stderr.puts 'warn'")
        #expect(result.stderr == "warn\n")
        #expect(result.stdout.isEmpty)
    }

    @Test func runReturnsLastExpressionValue() {
        // The last expression's to_s mirrors evaluate(); a bare expression with
        // no puts has empty stdout but a meaningful result.
        let result = RubyRuntime.shared.run("1 + 2")
        #expect(result.result == "3")
        #expect(result.stdout.isEmpty)
        #expect(!result.hasError)
    }

    @Test func runRaisesPopulateErrorAndPreservePartialStdout() {
        // A script that prints then raises: stdout holds what printed before the
        // raise, and the error message is set -- the console shows both. This is
        // the reason `run` is non-throwing (evaluate's throws path would drop the
        // partial stdout).
        let result = RubyRuntime.shared.run("puts 'before'; raise 'boom'")
        #expect(result.stdout == "before\n")
        #expect(result.hasError)
        #expect(result.errorMessage == "boom")
    }

    @Test func runPopulatesBacktraceOnRaise() {
        // A raise from inside a method: the backtrace holds at least the
        // method's frame and the top-level call site, in that order (innermost
        // first, matching Exception#backtrace).
        let result = RubyRuntime.shared.run("def foo\n  raise 'boom'\nend\nfoo")
        #expect(result.hasError)
        #expect(!result.backtrace.isEmpty)
        #expect(result.backtrace.first?.contains("foo") == true)
    }

    @Test func runLeavesBacktraceEmptyOnACleanRun() {
        let result = RubyRuntime.shared.run("1 + 2")
        #expect(!result.hasError)
        #expect(result.backtrace.isEmpty)
    }

    @Test func backtraceDoesNotLeakFromAPreviousRun() {
        // Guards the read-order choice in `run`: the backtrace must be read
        // right after the failing eval, before any later eval (e.g. reading
        // $cap_out.string) can overwrite $rc_last_error. A raise followed by a
        // clean run must leave the clean run's backtrace empty.
        _ = RubyRuntime.shared.run("raise 'boom'")
        let result = RubyRuntime.shared.run("1 + 1")
        #expect(!result.hasError)
        #expect(result.backtrace.isEmpty)
    }

    @Test func runRestoresStdoutAfterRunning() {
        // Capture must restore $stdout/$stderr afterward, or a later evaluate
        // would silently write to a StringIO and return empty. Drives a `run`,
        // then a plain `evaluate` whose puts should reach the real stdout (the
        // returned result proves the eval ran; the point is it didn't error).
        _ = RubyRuntime.shared.run("puts 'captured'")
        // After run, $stdout must be the real STDOUT again (not a StringIO),
        // otherwise this evaluate writes into the stale capture buffer.
        let restored = try? RubyRuntime.shared.evaluate(
            "$stdout == STDOUT ? 'restored' : 'still-captured'"
        )
        #expect(restored == "restored")
    }

    // MARK: - Top-level jumps (return/break/...) -- the shim's non-RAISE tag path
    //
    // Guards rubycuts_shim.c's rc_error_message_for_state: rb_eval_string_protect
    // surfaces a top-level `return` as TAG_RETURN (not TAG_RAISE), and ec->errinfo
    // is internal throw data, not a Ruby object. The old shim called
    // rb_obj_as_string on it and crashed the process (SIGSEGV inside rb_longjmp),
    // reproduced by running `return {}` in the console. The shim now synthesizes a
    // message for non-RAISE tags. Kept in this serialized suite (not a separate
    // one) so all VM-driving tests share one serial execution contract.

    @Test func topLevelReturnDoesNotCrash() {
        let result = RubyRuntime.shared.run("return {}")
        #expect(result.hasError)
        // Matches MRI's LocalJumpError wording for a top-level return.
        #expect(result.errorMessage == "unexpected return")
        #expect(result.stdout.isEmpty)
    }

    @Test func topLevelReturnLeavesBacktraceEmpty() {
        // Guards the shim's non-RAISE-tag branch: a top-level return has no
        // exception object, so $rc_last_error must be Qnil, not a stale
        // exception from an earlier raise. Self-contained (raises first) so
        // the guard doesn't depend on source-order relative to other tests.
        _ = RubyRuntime.shared.run("raise 'boom'")
        let result = RubyRuntime.shared.run("return {}")
        #expect(result.hasError)
        #expect(result.backtrace.isEmpty)
    }

    @Test func topLevelBreakReportsAnErrorWithoutCrashing() {
        // A bare `break` at the top level is a syntax error (a real TAG_RAISE
        // exception), not a TAG_BREAK jump -- so this exercises the shim's normal
        // exception-message path, not the synthesized-message path. It must not
        // crash and must report some error.
        let result = RubyRuntime.shared.run("break")
        #expect(result.hasError)
    }

    @Test func evaluateSurvivesTopLevelReturn() {
        // The fix is in the shim, so evaluate (not just run) is protected too: a
        // top-level return throws RubyError rather than crashing the runner.
        #expect(throws: RubyError.self) {
            _ = try RubyRuntime.shared.evaluate("return 1")
        }
    }

    @Test func vmIsUsableAfterATopLevelReturn() throws {
        // The throw data must be cleared so the VM is clean for later evals -- a
        // corrupted errinfo would surface as a crash or stale error next time.
        _ = RubyRuntime.shared.run("return {}")
        let ok = try RubyRuntime.shared.evaluate("1 + 1")
        #expect(ok == "2")
    }

    // MARK: - exit!/abort hardening
    //
    // Guards RubyRuntime.hardenProcessExit: exit!/abort call the real C exit()
    // directly, bypassing rb_eval_string_protect's catch, so a bare `exit!`
    // would kill the host app. Boot overrides Kernel#exit!/#abort to raise a
    // catchable SystemExit instead, so the run fails rather than the app dying.

    @Test func exitBangDoesNotKillTheHost() {
        // Before the override this terminated the test runner. Now it surfaces as
        // a SystemExit error and the process keeps running.
        let result = RubyRuntime.shared.run("exit!")
        #expect(result.hasError)
        #expect(result.errorMessage == "SystemExit")
    }

    @Test func exitBangWithStatusIsCatchable() {
        let result = RubyRuntime.shared.run("exit!(2)")
        #expect(result.hasError)
        #expect(result.errorMessage == "SystemExit")
    }

    @Test func abortDoesNotKillTheHost() {
        // abort routes through exit! internally; the override makes it raise too.
        let result = RubyRuntime.shared.run("abort")
        #expect(result.hasError)
        #expect(result.errorMessage == "SystemExit")
    }

    @Test func plainExitIsAlreadySafe() {
        // Regression guard: plain `exit` raises SystemExit natively (no override
        // needed) and was always caught. The message is MRI's "exit" string, not
        // "SystemExit" like the exit! override produces -- the point here is just
        // that it's caught and doesn't kill the host.
        let result = RubyRuntime.shared.run("exit")
        #expect(result.hasError)
    }

    @Test func vmIsUsableAfterAnExitBang() throws {
        _ = RubyRuntime.shared.run("exit!")
        let ok = try RubyRuntime.shared.evaluate("1 + 1")
        #expect(ok == "2")
    }

    // MARK: - "Run Ruby Script" App Intent integration (output-side, Phase 5)
    //
    // The one VM-driving contract for the App Intents slice: seed a temp-dir
    // store, resolve a stored script through the ``ScriptEntity`` picker path
    // (entity -> ``Script`` -> ``ScriptStore/source(of:)``), run it via
    // ``runToOutput(_:)``, and confirm the captured `$stdout` flows out to the
    // intent's return value. Kept in this `.serialized` suite -- not a second
    // one -- so all VM-driving tests share one serial execution contract (the
    // cross-suite double-load hazard the suite header warns about). The pure
    // ``output(from:)`` decision is covered separately in `IntentOutputTests`.

    @Test func runRubyScriptIntentFlowsStdoutOut() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsTests-\(UUID().uuidString)")
        let store = ScriptStore(directoryURL: dir)
        try store.ensureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = try store.create(name: "intent-smoke", source: "puts 'from-script'")
        let entity = ScriptEntity(script)

        // The intent's resolve path: ``ScriptEntity/script`` ->
        // ``ScriptStore/source(of:)`` -> ``runToOutput(_:)``.
        let resolved = try #require(entity.script)
        let source = try store.source(of: resolved)
        let output = try runToOutput(source)

        #expect(output == "from-script\n")
    }

    @Test func runRubyScriptIntentFailsOnRaise() throws {
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

        let resolved = try #require(entity.script)
        let source = try store.source(of: resolved)

        let error = try #require(throws: RubyRunError.self) {
            try runToOutput(source)
        }

        // The combined message leads with the exception's `to_s`, followed by
        // its backtrace (see ``combinedMessage(_:)`` in RubyIntents.swift).
        #expect(error.message.hasPrefix("boom\n"))
    }

    // MARK: - run(_:input:) -- ARGV / STDIN / ENV plumbing (Phase 4 input side)
    //
    // The VM-driving contract for the input slice: a non-empty ``RunInput``
    // reaches the script as `ARGV` / `$stdin` / `ENV`, an empty one runs today's
    // plain capture path, and the teardown restores prior state so a Shortcut
    // run's env never bleeds into a later console `evaluate`. Same `.serialized`
    // suite as every other VM-driving test -- the single interpreter is
    // non-thread-safe, so all VM work shares one serial execution contract.

    @Test func runReceivesArgv() {
        let result = RubyRuntime.shared.run("puts ARGV[0]", input: RunInput(argv: ["hello"]))
        #expect(result.stdout == "hello\n")
        #expect(!result.hasError)
    }

    @Test func runReceivesStdin() {
        let result = RubyRuntime.shared.run("puts $stdin.read", input: RunInput(stdin: "data"))
        #expect(result.stdout == "data\n")
        #expect(!result.hasError)
    }

    @Test func runReceivesEnv() {
        let result = RubyRuntime.shared.run(
            "puts ENV['MYKEY']", input: RunInput(env: [("MYKEY", "val")])
        )
        #expect(result.stdout == "val\n")
        #expect(!result.hasError)
    }

    @Test func runReceivesArgvStdinAndEnvTogether() {
        // All three channels coexist: ARGV joins, $stdin reads, ENV looks up.
        let input = RunInput(argv: ["a", "b"], stdin: "data", env: [("K", "v")])
        let result = RubyRuntime.shared.run(
            "puts ARGV.join(','); puts $stdin.read; puts ENV['K']", input: input
        )
        #expect(result.stdout == "a,b\ndata\nv\n")
        #expect(!result.hasError)
    }

    @Test func runWithEmptyInputLeavesArgvEmpty() {
        // The opt-in path: an empty RunInput runs the plain capture (no
        // ARGV setup), so ARGV is its default empty array.
        let result = RubyRuntime.shared.run("puts ARGV.length", input: .empty)
        #expect(result.stdout == "0\n")
        #expect(!result.hasError)
    }

    @Test func envRunDoesNotLeakIntoLaterEvaluations() throws {
        // Teardown must restore each ENV key to its prior state (absent here),
        // so a value a Shortcut run set doesn't bleed into the console or the
        // next run. `ENV['RC_X']` returns nil after teardown -> `nil.to_s` == "".
        _ = RubyRuntime.shared.run(
            "puts ENV['RC_X']", input: RunInput(env: [("RC_X", "secret")])
        )
        let leaked = try RubyRuntime.shared.evaluate("ENV['RC_X'].to_s")
        #expect(leaked == "")
    }

    @Test func envRunRestoresAPreviouslyPresentValue() throws {
        // When the key already had a value before the run, teardown restores
        // that prior value rather than deleting the key. Set a baseline in the
        // VM, run with an input that overwrites it, then confirm the baseline
        // survived.
        _ = try RubyRuntime.shared.evaluate("ENV['RC_Y'] = 'original'")
        _ = RubyRuntime.shared.run(
            "puts ENV['RC_Y']", input: RunInput(env: [("RC_Y", "overwritten")])
        )
        let restored = try RubyRuntime.shared.evaluate("ENV['RC_Y']")
        #expect(restored == "original")
        // Clean up the baseline so no test state leaks forward.
        _ = try? RubyRuntime.shared.evaluate("ENV.delete('RC_Y')")
    }

}
