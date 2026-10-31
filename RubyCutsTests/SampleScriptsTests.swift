@testable import RubyCuts
import Testing

// Pure tests over `SampleScripts.all`'s static content: no VM, no I/O. The
// suite is not `@MainActor`: `SampleScripts` opts out of the app target's
// MainActor-by-default isolation, matching `Script`/`RunInput`, so these run
// concurrently with everything else.
struct SampleScriptsTests {

    @Test func namesAreUniqueAndNonEmpty() {
        let names = SampleScripts.all.map(\.name)

        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { !$0.isEmpty })
    }

    @Test func sourcesAreNonEmpty() {
        #expect(SampleScripts.all.allSatisfy { !$0.source.isEmpty })
    }
}
