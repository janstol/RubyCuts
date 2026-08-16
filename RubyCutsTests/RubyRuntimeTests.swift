import Testing

@testable import RubyCuts

@MainActor
struct RubyRuntimeTests {

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
