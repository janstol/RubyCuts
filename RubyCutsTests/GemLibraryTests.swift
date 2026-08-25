import Foundation
import Testing

@testable import RubyCuts

/// A `RubyGemsAPI` stub that always fails to find any gem -- enough to drive
/// `GemLibrary.install(name:requirement:)` down its failure path offline,
/// without needing a real dependency graph like `GemResolverTests`' stub
/// provides.
private struct AlwaysFailingRubyGemsAPI: RubyGemsAPI {
    func versions(ofGem name: String) async throws -> [GemVersionInfo] {
        throw RubyGemsAPIError.gemNotFound(name)
    }

    func versionDetails(ofGem name: String, version: String) async throws -> GemVersionDetails {
        throw RubyGemsAPIError.gemNotFound(name)
    }
}

// Tests for the gems sheet's view model, mirroring `ScriptLibraryTests`.
// Each test builds its own library on a unique temp-dir `GemStore` and
// defers its removal. `@MainActor` because `GemLibrary`/`GemInstaller` are
// MainActor-isolated, matching `ScriptLibraryTests`.
@MainActor
@Suite
struct GemLibraryTests {

    private func makeStore() throws -> GemStore {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsTests-\(UUID().uuidString)")
        let store = GemStore(directoryURL: dir)
        try store.ensureDirectory()
        return store
    }

    @Test func installFailureSetsErrorMessageAndDoesNotClearIt() async throws {
        // Guards the exact bug found live-testing nokogiri: `install`
        // caught the resolver/installer error, set `errorMessage`, then
        // called `refresh()` unconditionally -- which resets `errorMessage`
        // to `nil` as its first line, silently wiping out the error it just
        // set. The failure must still be visible after `install` returns.
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let installer = GemInstaller(api: AlwaysFailingRubyGemsAPI(), store: store)
        let library = GemLibrary(store: store, installer: installer)

        await library.install(name: "does-not-exist", requirement: "")

        #expect(library.errorMessage != nil)
        #expect(library.gems.isEmpty)
    }

    @Test func installingABundledGemSurfacesTheBundledMessageInsteadOfInstalling() async throws {
        // sqlite3 is baked into the binary (see BundledGem) -- installing
        // it through the sheet must explain that, not silently no-op or
        // fail the C-extension check the way a genuinely unbundled
        // C-extension gem would.
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let installer = GemInstaller(api: AlwaysFailingRubyGemsAPI(), store: store)
        let library = GemLibrary(store: store, installer: installer)

        await library.install(name: "sqlite3", requirement: "")

        let message = try #require(library.errorMessage)
        #expect(message.contains("built into RubyCuts"))
        #expect(library.gems.isEmpty)
    }
}
