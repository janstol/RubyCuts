import Foundation
@testable import RubyCuts
import Testing

// Tests for the script list view model. Each test builds its own library on a
// unique temp-dir `ScriptStore` and defers its removal, so the tests are
// isolated with no shared VM state (no `.serialized` needed). The VM is
// MainActor-isolated via the app target's default actor isolation, so the suite
// is `@MainActor`: the methods under test touch `scripts`/`errorMessage`, which
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

    /// Builds a throwaway `UserDefaults` suite so seeding tests never touch
    /// `.standard`. Each test defers `removePersistentDomain(forName:)` on
    /// the returned name itself, mirroring `makeStore()`'s directory cleanup.
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "RubyCutsTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
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

    @Test func renameUpdatesTheScriptAndTheList() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let library = ScriptLibrary(store: store)
        let script = try #require(library.create(name: "before"))

        let renamed = library.rename(script, to: "after")

        #expect(renamed?.name == "after")
        #expect(library.scripts.count == 1)
        #expect(library.scripts.first == renamed)
        #expect(library.errorMessage == nil)
    }

    @Test func renameWithEmptyNameSetsErrorAndReturnsNil() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let library = ScriptLibrary(store: store)
        let script = try #require(library.create(name: "before"))

        // The store rejects empty/whitespace-only names; the VM surfaces
        // that as an error message and returns nil, same as `create`.
        let renamed = library.rename(script, to: "   ")

        #expect(renamed == nil)
        #expect(library.errorMessage != nil)
        // The rename never happened, so the original script is still listed
        // under its old name.
        #expect(library.scripts.count == 1)
        #expect(library.scripts.first?.name == "before")
    }

    // MARK: - Editor save hook

    @Test func renameFlushesTheRegisteredEditorHookBeforeMoving() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let library = ScriptLibrary(store: store)
        let script = try #require(library.create(name: "before"))
        library.registerEditorSave(for: script) {
            try? store.write(script, source: "flushed content")
            return true
        }

        let renamed = try #require(library.rename(script, to: "after"))

        // The flush wrote to the *old* URL before the move, so its content
        // has to have travelled along with the file to the new one.
        let contents = try String(contentsOf: renamed.url, encoding: .utf8)
        #expect(contents == "flushed content")
    }

    @Test func renameAbortsWhenTheHookFlushFails() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let library = ScriptLibrary(store: store)
        let script = try #require(library.create(name: "before"))
        library.registerEditorSave(for: script) {
            // Mirrors how a real editor's silent save reports failure: it
            // sets `errorMessage` itself through `onSaveError`, before
            // `rename` sees the `false` return.
            library.errorMessage = "flush failed"
            return false
        }

        let renamed = library.rename(script, to: "after")

        #expect(renamed == nil)
        // The flush's own message must survive, not be cleared by `rename`.
        #expect(library.errorMessage == "flush failed")
        // Nothing moved: the original file is still there and no file
        // exists under the new name.
        #expect(FileManager.default.fileExists(atPath: script.url.path))
        let newURL = store.directoryURL.appending(component: "after.rb")
        #expect(!FileManager.default.fileExists(atPath: newURL.path))
    }

    @Test func renameIgnoresAHookRegisteredForADifferentScript() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let library = ScriptLibrary(store: store)
        let target = try #require(library.create(name: "before"))
        let other = try #require(library.create(name: "other"))
        var flushCalled = false
        library.registerEditorSave(for: other) {
            flushCalled = true
            return false
        }

        let renamed = library.rename(target, to: "after")

        #expect(renamed?.name == "after")
        #expect(!flushCalled)
    }

    @Test func unregisterWithAMismatchedScriptLeavesTheRegistrationIntact() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let library = ScriptLibrary(store: store)
        let target = try #require(library.create(name: "before"))
        let other = try #require(library.create(name: "other"))
        var flushCalled = false
        library.registerEditorSave(for: target) {
            flushCalled = true
            return true
        }

        // The `.id(selection)` teardown-ordering case: a stale deregistration
        // for a different script must not clear this one's hook.
        library.unregisterEditorSave(for: other)
        _ = library.rename(target, to: "after")

        #expect(flushCalled)
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
        // The list stays consistent: nothing was created, so it's still empty.
        #expect(library.scripts.isEmpty)
    }

    @Test func deleteOfMissingFileSetsErrorAndStaysConsistent() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let library = ScriptLibrary(store: store)
        let script = library.create(name: "real")
        // Delete out from under the VM, then ask it to delete the same file
        // again. The store throws, which the VM surfaces as an error and
        // re-lists to keep `scripts` consistent.
        try store.delete(script ?? Script(url: store.directoryURL))
        library.refresh()
        #expect(library.scripts.isEmpty)

        let stale = Script(url: store.directoryURL.appending(component: "real.rb"))
        library.delete(stale)

        #expect(library.errorMessage != nil)
        #expect(library.scripts.isEmpty)
    }

    // MARK: - Sample seeding and restore

    @Test func seedingAnEmptyStoreCreatesAllFourSamples() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = ScriptLibrary(store: store, defaults: defaults)
        library.seedSamplesIfNeeded()

        let names = Set(library.scripts.map(\.name))
        #expect(names == Set(SampleScripts.all.map(\.name)))
        #expect(library.errorMessage == nil)
    }

    @Test func aSecondSeedCallIsANoOp() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = ScriptLibrary(store: store, defaults: defaults)
        library.seedSamplesIfNeeded()
        // Delete everything, then seed again: the flag set by the first
        // call must keep the second from bringing them back. That's what
        // makes a deleted sample stay deleted.
        for script in library.scripts {
            library.delete(script)
        }
        #expect(library.scripts.isEmpty)

        library.seedSamplesIfNeeded()

        #expect(library.scripts.isEmpty)
    }

    @Test func seedingLeavesANonEmptyStoreUntouchedButStillSetsTheFlag() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        _ = try store.create(name: "mine", source: "puts 1")

        let library = ScriptLibrary(store: store, defaults: defaults)
        library.seedSamplesIfNeeded()

        #expect(library.scripts.count == 1)
        #expect(library.scripts.first?.name == "mine")

        // The flag is set even though nothing was seeded: a second call
        // (e.g. the next launch) must not retroactively seed on top of it.
        library.seedSamplesIfNeeded()
        #expect(library.scripts.count == 1)
    }

    @Test func restoreSamplesRecreatesOnlyWhatsMissingWithNoSuffix() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = ScriptLibrary(store: store, defaults: defaults)
        library.seedSamplesIfNeeded()
        let toDelete = try #require(library.scripts.first)
        library.delete(toDelete)
        #expect(library.scripts.count == SampleScripts.all.count - 1)

        library.restoreSamples()

        let names = library.scripts.map(\.name)
        #expect(Set(names) == Set(SampleScripts.all.map(\.name)))
        // No `-2` suffix anywhere: restoring a missing sample must never
        // collide with the samples that were never deleted.
        #expect(!names.contains { $0.hasSuffix("-2") })
        #expect(library.errorMessage == nil)
    }

    // MARK: - Sort order

    /// Sets a script's modification date directly, so date-sort tests don't
    /// have to sleep between creates to get distinct timestamps.
    private func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func nameIsTheDefaultSortOrder() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = ScriptLibrary(store: store, defaults: defaults)

        #expect(library.sortOrder == .name)
    }

    @Test func dateModifiedOrdersNewestFirst() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let oldest = try store.create(name: "oldest", source: "")
        let middle = try store.create(name: "middle", source: "")
        let newest = try store.create(name: "newest", source: "")
        let now = Date()
        try setModificationDate(now.addingTimeInterval(-3600), at: oldest.url)
        try setModificationDate(now.addingTimeInterval(-1800), at: middle.url)
        try setModificationDate(now, at: newest.url)

        let library = ScriptLibrary(store: store, defaults: defaults)
        library.refresh()
        library.sortOrder = .dateModified

        #expect(library.scripts.map(\.name) == ["newest", "middle", "oldest"])
    }

    @Test func sortOrderChangeResortsWithoutAManualRefresh() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let alpha = try store.create(name: "alpha", source: "")
        let beta = try store.create(name: "beta", source: "")
        let now = Date()
        try setModificationDate(now.addingTimeInterval(-3600), at: alpha.url)
        try setModificationDate(now, at: beta.url)

        let library = ScriptLibrary(store: store, defaults: defaults)
        library.refresh()
        #expect(library.scripts.map(\.name) == ["alpha", "beta"])

        library.sortOrder = .dateModified

        // No `library.refresh()` call between the two assertions: the
        // `didSet` on `sortOrder` alone must re-order `scripts`.
        #expect(library.scripts.map(\.name) == ["beta", "alpha"])
    }

    @Test func sortOrderPersistsAcrossAFreshLibraryOnTheSameDefaults() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = ScriptLibrary(store: store, defaults: defaults)
        #expect(first.sortOrder == .name)
        first.sortOrder = .dateModified

        let second = ScriptLibrary(store: store, defaults: defaults)

        #expect(second.sortOrder == .dateModified)
    }

    // MARK: - iCloud seeding

    @Test func seedingSkipsWhenICloudAlreadyHasScripts() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = ScriptLibrary(store: store, defaults: defaults)
        // The store is empty on this device, but the metadata query knows of
        // scripts another device put in iCloud.
        library.seedSamplesIfNeeded(gatheredScriptCount: 3)

        #expect(library.scripts.isEmpty)
        // The flag is set, so a later launch doesn't seed either.
        library.seedSamplesIfNeeded()
        #expect(library.scripts.isEmpty)
    }

    @Test func prepareStorageOnAnInjectedStoreSeedsAndLists() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = ScriptLibrary(store: store, defaults: defaults)
        await library.prepareStorage()

        #expect(library.store.directoryURL == store.directoryURL)
        #expect(library.storageLocation == .local)
        #expect(Set(library.scripts.map(\.name)) == Set(SampleScripts.all.map(\.name)))
    }
}
