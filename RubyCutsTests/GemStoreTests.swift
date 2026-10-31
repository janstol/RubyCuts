import Foundation
@testable import RubyCuts
import Testing

// Tests for the installed-gem store, mirroring `ScriptStoreTests`. Each test
// builds its own store on a unique temp directory and defers its removal:
// isolated, safe to run concurrently, no `.serialized` needed.
struct GemStoreTests {

    /// Builds a store on a fresh unique temp directory and ensures it exists.
    private func makeStore() throws -> GemStore {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsTests-\(UUID().uuidString)")
        let store = GemStore(directoryURL: dir)
        try store.ensureDirectory()
        return store
    }

    /// Builds an already-extracted gem payload (just a `lib/` dir) at a fresh
    /// temp location, for feeding into `install(from:name:version:)`.
    private func makeExtractedPayload() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsTests-extracted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appending(component: "lib"), withIntermediateDirectories: true
        )
        return dir
    }

    @Test func ensureDirectoryIsIdempotent() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        #expect(FileManager.default.fileExists(atPath: store.directoryURL.path))
        try store.ensureDirectory()
        try store.ensureDirectory()
    }

    @Test func installThenListRoundTrips() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let payload = try makeExtractedPayload()

        let gem = try store.install(from: payload, name: "httparty", version: "0.21.0")

        #expect(gem.name == "httparty")
        #expect(gem.version == "0.21.0")
        #expect(try store.list() == [gem])
    }

    @Test func libURLPointsAtTheLibSubdirectory() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let payload = try makeExtractedPayload()

        let gem = try store.install(from: payload, name: "httparty", version: "0.21.0")

        #expect(gem.libURL == gem.directoryURL.appending(component: "lib"))
    }

    @Test func hyphenatedGemNameSplitsOnTheLastDash() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let payload = try makeExtractedPayload()

        let gem = try store.install(from: payload, name: "mini-portile2", version: "2.8.5")

        #expect(gem.name == "mini-portile2")
        #expect(gem.version == "2.8.5")
    }

    @Test func installingAnAlreadyInstalledNameThrows() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        _ = try store.install(from: try makeExtractedPayload(), name: "httparty", version: "0.21.0")

        #expect(throws: GemStoreError.alreadyInstalled("httparty")) {
            _ = try store.install(
                from: try makeExtractedPayload(), name: "httparty", version: "0.22.0"
            )
        }
    }

    @Test func isInstalledReflectsWhatsOnDisk() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }

        #expect(try !store.isInstalled("httparty"))
        _ = try store.install(from: try makeExtractedPayload(), name: "httparty", version: "0.21.0")
        #expect(try store.isInstalled("httparty"))
    }

    @Test func deleteRemovesTheDirectory() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let gem = try store.install(
            from: try makeExtractedPayload(), name: "httparty", version: "0.21.0"
        )

        try store.delete(gem)

        #expect(try store.list().isEmpty)
    }

    @Test func listSortsByNameThenVersion() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        _ = try store.install(from: try makeExtractedPayload(), name: "csv", version: "3.3.0")
        _ = try store.install(
            from: try makeExtractedPayload(), name: "httparty", version: "0.21.0"
        )

        let names = try store.list().map(\.name)

        #expect(names == ["csv", "httparty"])
    }

    @Test func listSkipsNonDirectoryEntries() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        _ = try store.install(from: try makeExtractedPayload(), name: "httparty", version: "0.21.0")
        let stray = store.directoryURL.appending(component: "stray.txt")
        try "not a gem".write(to: stray, atomically: true, encoding: .utf8)

        let listed = try store.list()

        #expect(listed.count == 1)
        #expect(listed.first?.name == "httparty")
    }
}
