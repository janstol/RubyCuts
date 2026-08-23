import Foundation
import Testing

@testable import RubyCuts

// Tests for the script list view model. Each test builds its own library on a
// unique temp-dir `ScriptStore` and defers its removal, so the tests are
// isolated with no shared VM state (no `.serialized` needed). The VM is
// MainActor-isolated via the app target's default actor isolation, so the suite
// is `@MainActor` -- the methods under test touch `scripts`/`errorMessage`, which
// are MainActor-coupled state.
@MainActor
@Suite
struct ScriptLibraryTests {

    /// Builds a store on a fresh unique temp directory and ensures it exists.
    /// Each test defers removal of `store.directoryURL` itself; a new directory
    /// per test means `list()`/collisions start from empty every time.
    private func makeStore() throws -> ScriptStore {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsTests-\(UUID().uuidString)")
        let store = ScriptStore(directoryURL: dir)
        try store.ensureDirectory()
        return store
    }

    @Test func refreshReflectsCreatedScripts() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let library = ScriptLibrary(store: store)
        _ = try store.create(name: "alpha", source: "puts 1")

        library.refresh()

        #expect(library.scripts.count == 1)
        #expect(library.scripts.first?.name == "alpha")
        #expect(library.errorMessage == nil)
    }

    @Test func createAppendsAndReturnsTheScript() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let library = ScriptLibrary(store: store)
        library.refresh()
        #expect(library.scripts.isEmpty)

        let script = library.create(name: "hello")

        #expect(script != nil)
        #expect(library.scripts.count == 1)
        // The returned script is the one now in the list.
        #expect(library.scripts.first == script)
        #expect(library.errorMessage == nil)
    }

    @Test func createWithDuplicateNameStillSucceeds() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let library = ScriptLibrary(store: store)
        _ = library.create(name: "hello")
        // A second create with the same name must not fail: collision-suffixing
        // is ScriptStore's job, so the VM just passes through.
        let second = library.create(name: "hello")

        #expect(second != nil)
        #expect(library.scripts.count == 2)
        #expect(second?.name == "hello-2")
        #expect(library.errorMessage == nil)
    }

    @Test func deleteRemovesTheScript() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let library = ScriptLibrary(store: store)
        let script = library.create(name: "gone")
        #expect(library.scripts.count == 1)

        library.delete(script ?? Script(url: store.directoryURL))

        #expect(library.scripts.isEmpty)
        #expect(library.errorMessage == nil)
    }

    @Test func createWithEmptyNameSetsErrorAndReturnsNil() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let library = ScriptLibrary(store: store)
        library.refresh()

        // The store rejects empty/whitespace-only names; the VM surfaces that as
        // an error message and returns nil rather than throwing through SwiftUI.
        let script = library.create(name: "   ")

        #expect(script == nil)
        #expect(library.errorMessage != nil)
        // The list stays consistent -- nothing was created, so it's still empty.
        #expect(library.scripts.isEmpty)
    }

    @Test func deleteOfMissingFileSetsErrorAndStaysConsistent() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let library = ScriptLibrary(store: store)
        let script = library.create(name: "real")
        // Delete out from under the VM, then ask it to delete the same file
        // again -- the store throws, which the VM surfaces as an error and
        // re-lists to keep `scripts` consistent.
        try store.delete(script ?? Script(url: store.directoryURL))
        library.refresh()
        #expect(library.scripts.isEmpty)

        let stale = Script(url: store.directoryURL.appending(component: "real.rb"))
        library.delete(stale)

        #expect(library.errorMessage != nil)
        #expect(library.scripts.isEmpty)
    }
}
