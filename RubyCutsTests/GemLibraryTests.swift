import Foundation
import Testing

@testable import RubyCuts

/// A `RubyGemsAPI` stub that always fails to find any gem -- enough to drive
/// `GemLibrary.prepareInstall(name:requirement:)` down its failure path
/// offline, without needing a real dependency graph like `StubRubyGemsAPI`
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

    /// httparty's real runtime dependency shape (per the Phase 7 plan's PRD
    /// success metric): resolving httparty must pull in csv, mini_mime, and
    /// multi_xml. Mirrors `GemResolverTests.httpartyCatalog`.
    private static let httpartyCatalog: [String: [StubRubyGemsAPI.Version]] = [
        "httparty": [
            StubRubyGemsAPI.Version(
                "0.22.0",
                dependencies: [
                    ("csv", "~> 3.0"),
                    ("mini_mime", ">= 1.0.0"),
                    ("multi_xml", ">= 0.5.2"),
                ]
            )
        ],
        "csv": [StubRubyGemsAPI.Version("3.3.0")],
        "mini_mime": [StubRubyGemsAPI.Version("1.1.5")],
        "multi_xml": [StubRubyGemsAPI.Version("0.7.1")],
    ]

    private func makeStore() throws -> GemStore {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsTests-\(UUID().uuidString)")
        let store = GemStore(directoryURL: dir)
        try store.ensureDirectory()
        return store
    }

    @Test func prepareInstallParksTheResolvedPlanWithoutDownloadingAnything() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let installer = GemInstaller(
            api: StubRubyGemsAPI(catalog: Self.httpartyCatalog), store: store
        )
        let library = GemLibrary(store: store, installer: installer)

        await library.prepareInstall(name: "httparty", requirement: "")

        guard case .readyToInstall(let plan, let requested) = library.installState else {
            Issue.record("expected .readyToInstall, got \(library.installState)")
            return
        }
        #expect(requested == "httparty")
        #expect(Set(plan.map(\.name)) == ["httparty", "csv", "mini_mime", "multi_xml"])
        #expect(library.errorMessage == nil)
        #expect(try store.list().isEmpty)
    }

    @Test func prepareInstallFailureSetsErrorMessageAndReturnsToIdle() async throws {
        // Guards the resolve-path clobber this pair used to cover under
        // `install(name:requirement:)`: a failure must set `errorMessage`
        // and leave the state machine idle, not parked mid-flow.
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let installer = GemInstaller(api: AlwaysFailingRubyGemsAPI(), store: store)
        let library = GemLibrary(store: store, installer: installer)

        await library.prepareInstall(name: "does-not-exist", requirement: "")

        #expect(library.errorMessage != nil)
        #expect(library.installState == .idle)
        #expect(library.gems.isEmpty)
    }

    @Test func prepareInstallOnABundledGemSurfacesTheBundledMessageInsteadOfAPlan() async throws {
        // sqlite3 is baked into the binary (see BundledGem) -- resolving it
        // through the sheet must explain that, not silently no-op or park a
        // plan that would fail the C-extension check on confirm.
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let installer = GemInstaller(api: AlwaysFailingRubyGemsAPI(), store: store)
        let library = GemLibrary(store: store, installer: installer)

        await library.prepareInstall(name: "sqlite3", requirement: "")

        let message = try #require(library.errorMessage)
        #expect(message.contains("built into RubyCuts"))
        #expect(library.installState == .idle)
    }

    @Test func prepareInstallOnAnAlreadyInstalledGemSurfacesTheAlreadyInstalledMessage()
        async throws
    {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let gemLibDir = store.destinationURL(name: "csv", version: "3.3.0")
            .appending(component: "lib")
        try FileManager.default.createDirectory(at: gemLibDir, withIntermediateDirectories: true)

        let installer = GemInstaller(
            api: StubRubyGemsAPI(catalog: Self.httpartyCatalog), store: store
        )
        let library = GemLibrary(store: store, installer: installer)

        await library.prepareInstall(name: "csv", requirement: "")

        let message = try #require(library.errorMessage)
        #expect(message.contains("already installed"))
        #expect(library.installState == .idle)
    }

    @Test func cancelPendingInstallReturnsToIdle() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let installer = GemInstaller(
            api: StubRubyGemsAPI(catalog: Self.httpartyCatalog), store: store
        )
        let library = GemLibrary(store: store, installer: installer)
        await library.prepareInstall(name: "httparty", requirement: "")
        guard case .readyToInstall = library.installState else {
            Issue.record("expected .readyToInstall before cancelling")
            return
        }

        library.cancelPendingInstall()

        #expect(library.installState == .idle)
    }

    @Test func confirmInstallWithNoParkedPlanIsANoOp() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let installer = GemInstaller(api: AlwaysFailingRubyGemsAPI(), store: store)
        let library = GemLibrary(store: store, installer: installer)

        await library.confirmInstall()

        #expect(library.installState == .idle)
        #expect(library.errorMessage == nil)
        #expect(library.gems.isEmpty)
    }

    @Test func downloadingPhaseLabelAndFractionCompleted() {
        let phase = GemInstallPhase.downloading(gem: "csv", index: 1, total: 4)

        #expect(phase.label == "Downloading csv (2 of 4)")
        #expect(phase.fractionCompleted == 0.25)
    }

    @Test func extractingPhaseLabelAndFractionCompleted() {
        let phase = GemInstallPhase.extracting(gem: "csv", index: 1, total: 4)

        #expect(phase.label == "Extracting csv (2 of 4)")
        #expect(phase.fractionCompleted == 0.375)
    }
}
