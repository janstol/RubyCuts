import Foundation
import Testing

@testable import RubyCuts

// Tests for the local-first script store. Each test builds its own store on a
// unique temp directory and defers its removal, so the tests are isolated and
// safe to run concurrently (no `.serialized` needed, unlike `RubyRuntimeTests`
// which drives a single non-thread-safe VM). No `@MainActor` either: there's
// no view model or shared actor involved, just synchronous file I/O.
struct ScriptStoreTests {

    /// Builds a store on a fresh unique temp directory and ensures it exists.
    /// Each test defers removal of `store.directoryURL` itself; a new directory
    /// per test means `list()`/collisions start from empty every time, with no
    /// cross-test ordering sensitivity.
    private func makeStore() throws -> ScriptStore {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsTests-\(UUID().uuidString)")
        let store = ScriptStore(directoryURL: dir)
        try store.ensureDirectory()
        return store
    }

    @Test func ensureDirectoryIsIdempotent() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        // A second createDirectory call on an existing directory must not throw.
        #expect(FileManager.default.fileExists(atPath: store.directoryURL.path))
        try store.ensureDirectory()  // no throw
        try store.ensureDirectory()  // still no throw
    }

    @Test func createThenListRoundTrips() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let script = try store.create(name: "hello", source: "puts 'hi'")

        let listed = try store.list()
        #expect(listed == [script])
        #expect(listed.first?.name == "hello")
    }

    @Test func listSkipsNonRubyFiles() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        _ = try store.create(name: "keep", source: "puts 'hi'")
        // A non-.rb file in the directory must not show up as a script.
        let other = store.directoryURL.appending(component: "notes.txt")
        try "ignore me".write(to: other, atomically: true, encoding: .utf8)

        let listed = try store.list()
        #expect(listed.count == 1)
        #expect(listed.first?.name == "keep")
    }

    @Test func sourceReadsBackWhatCreateWrote() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let script = try store.create(name: "echo", source: "puts 42")

        let read = try store.source(of: script)
        #expect(read == "puts 42")
    }

    @Test func writeOverwritesTheFile() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let script = try store.create(name: "draft", source: "old")

        try store.write(script, source: "new")
        #expect(try store.source(of: script) == "new")
        // The URL doesn't change on overwrite, only the contents.
        #expect(try store.list() == [script])
    }

    @Test func renameMovesAndReturnsTheNewURL() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let script = try store.create(name: "before", source: "puts 1")

        let renamed = try store.rename(script, to: "after")

        #expect(renamed.name == "after")
        #expect(renamed.url != script.url)
        // The old file is gone; only the renamed one remains.
        #expect(try store.list() == [renamed])
        #expect(try store.source(of: renamed) == "puts 1")
    }

    @Test func deleteRemovesTheFile() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let script = try store.create(name: "gone", source: "puts 0")

        try store.delete(script)

        #expect(try store.list().isEmpty)
    }

    @Test func nameCollisionProducesASuffixInsteadOfOverwriting() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        let first = try store.create(name: "hello", source: "v1")
        // A second create with the same name must not clobber `first`; it
        // writes to hello-2.rb instead.
        let second = try store.create(name: "hello", source: "v2")

        #expect(second.name == "hello-2")
        #expect(try store.source(of: first) == "v1")
        #expect(try store.source(of: second) == "v2")
        #expect(try store.list().count == 2)
    }

    @Test func nameWithRBExtensionIsNotDoubleSuffixed() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        // A caller who passes `foo.rb` should get `foo.rb`, not `foo.rb.rb`.
        let script = try store.create(name: "foo.rb", source: "x")

        #expect(script.name == "foo")
        #expect(script.url.lastPathComponent == "foo.rb")
    }

    @Test func emptyNameThrows() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        #expect(throws: ScriptStoreError.invalidName) {
            _ = try store.create(name: "", source: "x")
        }
    }

    @Test func whitespaceOnlyNameThrows() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        #expect(throws: ScriptStoreError.invalidName) {
            _ = try store.create(name: "   ", source: "x")
        }
    }

    // MARK: - modifiedAt

    @Test func listPopulatesModifiedAt() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        _ = try store.create(name: "hello", source: "puts 'hi'")

        let listed = try store.list()
        let modifiedAt = try #require(listed.first?.modifiedAt)
        // Just-created, so the recorded modification time should be within
        // a generous window of now, not asserting an exact value, since
        // that would couple the test to filesystem timestamp precision.
        #expect(abs(modifiedAt.timeIntervalSinceNow) < 60)
    }

    // MARK: - Only regular files are scripts

    /// A directory named `archive.rb`, holding one file, inside `store`.
    private func makeRubyNamedDirectory(in store: ScriptStore) throws -> URL {
        let directory = store.directoryURL.appending(
            component: "archive.rb", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "keep me".write(
            to: directory.appending(component: "child.txt"), atomically: true, encoding: .utf8)
        return directory
    }

    @Test func listSkipsADirectoryNamedLikeAScript() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        _ = try makeRubyNamedDirectory(in: store)
        _ = try store.create(name: "real", source: "puts 1")

        #expect(try store.list().map(\.name) == ["real"])
    }

    @Test func deleteRefusesADirectoryAndLeavesItsContents() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let directory = try makeRubyNamedDirectory(in: store)

        #expect(throws: ScriptStoreError.self) {
            try store.delete(Script(url: directory))
        }
        let child = directory.appending(component: "child.txt")
        #expect(FileManager.default.fileExists(atPath: child.path))
    }

    @Test func renameRefusesADirectory() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let directory = try makeRubyNamedDirectory(in: store)

        #expect(throws: ScriptStoreError.self) {
            _ = try store.rename(Script(url: directory), to: "moved")
        }
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func listSkipsASymlinkEvenToARealScript() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let real = try store.create(name: "real", source: "puts 1")
        let link = store.directoryURL.appending(component: "alias.rb")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.url)

        #expect(try store.list().map(\.name) == ["real"])
        #expect(throws: ScriptStoreError.self) {
            try store.delete(Script(url: link))
        }
        #expect(FileManager.default.fileExists(atPath: real.url.path))
    }

    @Test func deleteStillRemovesARegularScript() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let script = try store.create(name: "gone", source: "puts 1")

        try store.delete(script)

        #expect(try store.list().isEmpty)
    }
}
