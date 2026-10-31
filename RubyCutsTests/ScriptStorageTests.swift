import Foundation
@testable import RubyCuts
import Testing

// Tests for choosing where scripts live and for moving local scripts into
// iCloud. The iCloud container is stood in for by a temp directory through the
// injectable lookup and move functions, so nothing here touches iCloud.
struct ScriptStorageTests {

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsTests-\(UUID().uuidString)")
    }

    private func makeStore() throws -> ScriptStore {
        let store = ScriptStore(directoryURL: makeDirectory())
        try store.ensureDirectory()
        return store
    }

    /// Stands in for `setUbiquitous`, which needs a real iCloud container.
    private let plainMove: @Sendable (URL, URL) throws -> Void = { from, to in
        try FileManager.default.moveItem(at: from, to: to)
    }

    // MARK: - Resolver

    @Test func resolveFallsBackToLocalWithoutAContainer() async {
        let resolved = await ScriptStorage.resolve(containerLookup: { nil })

        #expect(resolved.location == .local)
        #expect(resolved.store.directoryURL == ScriptStore.local.directoryURL)
    }

    @Test func resolveUsesTheContainersDocumentsFolder() async {
        let container = makeDirectory()

        let resolved = await ScriptStorage.resolve(containerLookup: { container })

        #expect(resolved.location == .iCloud)
        // Compared as paths: the resolver marks the folder as a directory, so
        // its URL carries a trailing slash the plain `appending` doesn't.
        let expected = container.appending(component: "Documents").path(percentEncoded: false)
        #expect(resolved.store.directoryURL.path(percentEncoded: false) == expected + "/")
    }

    // MARK: - Moving local scripts in

    @Test func moveBringsEveryScriptAcross() async throws {
        let local = try makeStore()
        let cloud = ScriptStore(directoryURL: makeDirectory())
        defer {
            try? FileManager.default.removeItem(at: local.directoryURL)
            try? FileManager.default.removeItem(at: cloud.directoryURL)
        }
        _ = try local.create(name: "one", source: "puts 1")
        _ = try local.create(name: "two", source: "puts 2")

        let moved = try await ScriptStorage.moveScripts(from: local, into: cloud, move: plainMove)

        #expect(Set(moved.map(\.name)) == ["one", "two"])
        #expect(try local.list().isEmpty)
        #expect(try cloud.list().map(\.name) == ["one", "two"])
    }

    @Test func moveRenamesOnAClashInsteadOfOverwriting() async throws {
        let local = try makeStore()
        let cloud = try makeStore()
        defer {
            try? FileManager.default.removeItem(at: local.directoryURL)
            try? FileManager.default.removeItem(at: cloud.directoryURL)
        }
        let existing = try cloud.create(name: "hello", source: "from iCloud")
        _ = try local.create(name: "hello", source: "from this device")

        let moved = try await ScriptStorage.moveScripts(from: local, into: cloud, move: plainMove)

        #expect(moved.map(\.name) == ["hello-2"])
        #expect(try cloud.source(of: existing) == "from iCloud")
        #expect(try cloud.source(of: moved[0]) == "from this device")
    }

    @Test func moveSkipsDirectoriesAndSymlinks() async throws {
        let local = try makeStore()
        let cloud = try makeStore()
        defer {
            try? FileManager.default.removeItem(at: local.directoryURL)
            try? FileManager.default.removeItem(at: cloud.directoryURL)
        }
        let folder = local.directoryURL.appending(component: "archive.rb")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = try local.create(name: "real", source: "puts 1")
        try FileManager.default.createSymbolicLink(
            at: local.directoryURL.appending(component: "link.rb"), withDestinationURL: target.url)

        let moved = try await ScriptStorage.moveScripts(from: local, into: cloud, move: plainMove)

        #expect(moved.map(\.name) == ["real"])
        #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        #expect(try cloud.list().map(\.name) == ["real"])
    }

    @Test func aFailedMoveStillMovesTheRestAndThrows() async throws {
        let local = try makeStore()
        let cloud = try makeStore()
        defer {
            try? FileManager.default.removeItem(at: local.directoryURL)
            try? FileManager.default.removeItem(at: cloud.directoryURL)
        }
        _ = try local.create(name: "bad", source: "")
        _ = try local.create(name: "good", source: "")
        let failingForBad: @Sendable (URL, URL) throws -> Void = { from, to in
            if from.lastPathComponent == "bad.rb" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: from, to: to)
        }

        await #expect(throws: CocoaError.self) {
            try await ScriptStorage.moveScripts(from: local, into: cloud, move: failingForBad)
        }
        #expect(try cloud.list().map(\.name) == ["good"])
        #expect(try local.list().map(\.name) == ["bad"])
    }

    // MARK: - Shortcuts entity identity

    @Test func anEntityIdIsTheFileNameAndResolvesInAnyStore() throws {
        let first = try makeStore()
        let second = try makeStore()
        defer {
            try? FileManager.default.removeItem(at: first.directoryURL)
            try? FileManager.default.removeItem(at: second.directoryURL)
        }
        let script = try first.create(name: "hello", source: "puts 1")

        let entity = ScriptEntity(script)

        #expect(entity.id == "hello.rb")
        #expect(entity.script(in: first) == script)
        #expect(
            entity.script(in: second)?.url == second.directoryURL.appending(component: "hello.rb"))
    }

    @Test(arguments: ["", ".", "..", "../escape.rb", "sub/hello.rb", "/etc/passwd"])
    func anEntityIdWithAPathResolvesToNothing(id: String) throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        #expect(ScriptEntity(id: id, name: "x").script(in: store) == nil)
    }
}
