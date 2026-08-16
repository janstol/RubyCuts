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

}
