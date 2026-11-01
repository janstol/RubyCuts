@testable import RubyCuts
import Testing

// Keeps the documentation's code examples honest: every example must compile,
// and every example marked `.runs` is executed with its Shortcut input and
// checked against its expected output or error. Examples that touch the
// clipboard, notifications or the network are `.compilesOnly`. Nested under
// `EmbeddedRubyTests` so `.serialized` covers the single non-thread-safe
// interpreter; see that type's doc comment.
extension EmbeddedRubyTests {
    @MainActor
    @Suite(.serialized)
    struct DocExampleTests {
        @Test(arguments: DocCatalog.allExamples)
        func compilesWithoutSyntaxError(_ example: DocExample) async throws {
            // Base64-transported like `SampleScriptCompilationTests`, so the
            // embedded literal needs no escaping.
            let encoded = RubyRuntime.base64(example.code)
            _ = try await RubyRuntime.shared.evaluate(
                "require 'base64'; RubyVM::InstructionSequence.compile(Base64.decode64(\"\(encoded)\"))"
            )
        }

        @Test(arguments: DocCatalog.runnableExamples)
        func runsAsDocumented(_ example: DocExample) async throws {
            guard
                case .runs(let argv, let stdin, let env, let expectedStdout, let expectedError) =
                    example.verification
            else {
                Issue.record("\(example.title) is not runnable")
                return
            }
            let input = RunInput(
                argv: argv, stdin: stdin,
                env: env.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) })
            let result = await RubyRuntime.shared.run(example.code, input: input)

            if let expectedError {
                #expect(result.errorMessage == expectedError)
            } else {
                #expect(result.errorMessage == nil)
                #expect(result.stderr.isEmpty)
                if let expectedStdout {
                    #expect(result.stdout == expectedStdout)
                }
            }
        }
    }
}
