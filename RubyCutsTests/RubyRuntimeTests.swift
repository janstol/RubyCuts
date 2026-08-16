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

    @Test func loadPathIsExactlyTheBundledStdlib() throws {
        // The test that would have caught a dev-machine-only pass: without this, macOS
        // could keep working via stale .build-cruby paths seeded by ruby_init_loadpath()
        // while the same code silently ships broken on device.
        let count = try RubyRuntime.shared.evaluate("$LOAD_PATH.length")
        #expect(count == "1")

        let lastEntry = try RubyRuntime.shared.evaluate("$LOAD_PATH.last")
        #expect(lastEntry.hasSuffix("/stdlib"))
    }

    @Test func reportsEncodingDatabaseIsLoaded() throws {
        // Fails if Init_enc() didn't run.
        let result = try RubyRuntime.shared.evaluate("Encoding.find('Shift_JIS').name")
        #expect(result == "Shift_JIS")
    }

}
