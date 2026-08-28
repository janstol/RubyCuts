import Testing

@testable import RubyCuts

// Compiles every seeded sample's source inside the real VM and expects no
// `SyntaxError` -- catches a typo in shipped sample code without *executing*
// it, so this test causes no clipboard writes, no notifications, and no
// network. Nested under `EmbeddedRubyTests` so `.serialized` covers the same
// single non-thread-safe interpreter as `RubyRuntimeTests`,
// `NativeBridgeTests`, and `GemArchiveTests` -- see that type's doc comment.
extension EmbeddedRubyTests {
    @MainActor
    @Suite(.serialized)
    struct SampleScriptCompilationTests {
        @Test(arguments: SampleScripts.all)
        func compilesWithoutSyntaxError(_ sample: SampleScripts.Sample) async throws {
            // The source is base64-transported into the eval'd Ruby, the same
            // trick `RubyRuntime.inputSetup(for:)` uses, so the embedded
            // literal needs no escaping and round-trips the source exactly.
            let encoded = RubyRuntime.base64(sample.source)
            _ = try await RubyRuntime.shared.evaluate(
                "require 'base64'; RubyVM::InstructionSequence.compile(Base64.decode64(\"\(encoded)\"))"
            )
        }
    }
}
