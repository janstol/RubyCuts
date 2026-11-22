import Foundation
@testable import RubyCuts
import Testing

// Drives the shared VM, so it's nested under EmbeddedRubyTests for the same serialized execution as the other VM suites; see that type's doc comment.
extension EmbeddedRubyTests {
    @Suite(.serialized)
    struct RunIsolationTests {
        @Test func runningAScriptWithConstantsTwiceDoesNotWarn() async {
            let script =
                #"TOKEN_FOR_TEST = "secret"; URL_FOR_TEST = URI("https://example.com"); puts TOKEN_FOR_TEST"#
            _ = await RubyRuntime.shared.run("require 'uri'; " + script)
            let second = await RubyRuntime.shared.run(script)
            #expect(second.stderr.isEmpty, "got: \(second.stderr)")
            #expect(second.stdout == "secret\n")
            #expect(second.errorMessage == nil)
        }

        @Test func aLaterRunDoesNotSeeAnEarlierRunsPlainConstants() async {
            _ = await RubyRuntime.shared.run("LEFTOVER_FOR_TEST = 1")
            let result = await RubyRuntime.shared.run("puts defined?(LEFTOVER_FOR_TEST).inspect")
            #expect(result.stdout == "nil\n")
        }

        @Test func classesAndRequiredLibrariesStayLoaded() async {
            _ = await RubyRuntime.shared.run(
                "require 'set'; class KeptForTest; def self.hi = 'hi'; end")
            let result = await RubyRuntime.shared.run("puts KeptForTest.hi; puts Set.new([1]).size")
            #expect(result.stdout == "hi\n1\n")
            #expect(result.errorMessage == nil)
        }

        @Test func constantsFromBootAreKept() async {
            _ = await RubyRuntime.shared.run("1")
            let result = await RubyRuntime.shared.run(
                "puts [RUBY_VERSION, ARGV.class, RbConfig.class, WidgetUI.class].inspect")
            #expect(result.stdout == #"["3.4.9", Array, Module, Class]"# + "\n")
        }
    }
}
