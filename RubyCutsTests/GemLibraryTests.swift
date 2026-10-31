import Foundation
@testable import RubyCuts
import Testing

/// A `RubyGemsAPI` stub that always fails to find any gem, enough to drive
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

    func search(query: String) async throws -> [GemSearchResult] {
        throw RubyGemsAPIError.gemNotFound(query)
    }
}

/// A `RubyGemsAPI` stub that fails the test if it's called at all, for
/// paths that must be rejected before any network request.
private struct UnreachableRubyGemsAPI: RubyGemsAPI {
    func versions(ofGem name: String) async throws -> [GemVersionInfo] {
        Issue.record("unexpected versions(ofGem: \(name)) call")
        throw RubyGemsAPIError.gemNotFound(name)
    }

    func versionDetails(ofGem name: String, version: String) async throws -> GemVersionDetails {
        Issue.record("unexpected versionDetails(ofGem: \(name)) call")
        throw RubyGemsAPIError.gemNotFound(name)
    }

    func search(query: String) async throws -> [GemSearchResult] {
        Issue.record("unexpected search(query: \(query)) call")
        throw RubyGemsAPIError.gemNotFound(query)
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

    @Test(arguments: ["~>> 1.0", "~> \(Int.max)", "latest"])
    func prepareInstallRejectsAMalformedRequirementWithoutAnyNetworkRequest(
        requirement: String
    ) async throws {
        // A typo in the requirement must not be dropped and silently resolve
        // the newest version. UnreachableRubyGemsAPI records an issue if
        // resolution reaches the network at all.
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let installer = GemInstaller(api: UnreachableRubyGemsAPI(), store: store)
        let library = GemLibrary(store: store, installer: installer)

        await library.prepareInstall(name: "httparty", requirement: requirement)

        let message = try #require(library.errorMessage)
        #expect(message.contains("'\(requirement)' isn't a valid version requirement"))
        #expect(library.installState == .idle)
    }

    @Test func prepareInstallOnABundledGemSurfacesTheBundledMessageInsteadOfAPlan() async throws {
        // sqlite3 is baked into the binary (see BundledGem), so resolving it
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

    @Test func searchPopulatesResultsWithTheMatchingNames() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let installer = GemInstaller(
            api: StubRubyGemsAPI(catalog: Self.httpartyCatalog), store: store
        )
        let library = GemLibrary(store: store, installer: installer)

        await library.search(query: "m")

        guard case .results(let results) = library.searchState else {
            Issue.record("expected .results, got \(library.searchState)")
            return
        }
        #expect(Set(results.map(\.name)) == ["mini_mime", "multi_xml"])
    }

    @Test func searchWithAnEmptyOrWhitespaceQueryResetsToIdleWithoutARequest() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let installer = GemInstaller(api: AlwaysFailingRubyGemsAPI(), store: store)
        let library = GemLibrary(store: store, installer: installer)

        await library.search(query: "   ")

        #expect(library.searchState == .idle)
    }

    @Test func searchFailureSetsFailedStateButNotErrorMessage() async throws {
        // Guards the no-modal-alert decision: a search failure must not pop
        // an alert mid-typing, only the inline `.failed` state.
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let installer = GemInstaller(api: AlwaysFailingRubyGemsAPI(), store: store)
        let library = GemLibrary(store: store, installer: installer)

        await library.search(query: "httparty")

        guard case .failed = library.searchState else {
            Issue.record("expected .failed, got \(library.searchState)")
            return
        }
        #expect(library.errorMessage == nil)
    }

    @Test func clearSearchReturnsToIdle() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let installer = GemInstaller(
            api: StubRubyGemsAPI(catalog: Self.httpartyCatalog), store: store
        )
        let library = GemLibrary(store: store, installer: installer)
        await library.search(query: "httparty")

        library.clearSearch()

        #expect(library.searchState == .idle)
    }

    @Test func isAvailableCoversBundledDiskAndUnknownGems() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let gemLibDir = store.destinationURL(name: "csv", version: "3.3.0")
            .appending(component: "lib")
        try FileManager.default.createDirectory(at: gemLibDir, withIntermediateDirectories: true)
        let library = GemLibrary(store: store, installer: GemInstaller(store: store))
        library.refresh()

        #expect(library.isAvailable("sqlite3"))
        #expect(library.isAvailable("csv"))
        #expect(!library.isAvailable("httparty"))
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

    // MARK: - Dependency metadata: used by, delete warnings, orphans

    /// Creates an installed gem directory, with ``GemMetadata`` when
    /// `metadata` is given (a gem installed before metadata existed has none).
    @discardableResult
    private func installFake(
        _ name: String, _ version: String, in store: GemStore, metadata: GemMetadata?
    ) throws -> InstalledGem {
        let directory = store.destinationURL(name: name, version: version)
        try FileManager.default.createDirectory(
            at: directory.appending(component: "lib"), withIntermediateDirectories: true)
        if let metadata {
            try GemStore.writeMetadata(metadata, into: directory)
        }
        return InstalledGem(directoryURL: directory)
    }

    /// httparty as installed: requested, with csv, mini_mime and multi_xml as
    /// dependencies, and multi_xml pulling in bigdecimal.
    private func makeHttpartyLibrary(in store: GemStore) throws -> GemLibrary {
        let dependency = { (deps: [String]) in GemMetadata(requested: false, dependencies: deps) }
        try installFake(
            "httparty", "0.24.2", in: store,
            metadata: GemMetadata(requested: true, dependencies: ["csv", "mini_mime", "multi_xml"]))
        try installFake("csv", "3.3.6", in: store, metadata: dependency([]))
        try installFake("mini_mime", "1.1.5", in: store, metadata: dependency([]))
        try installFake("multi_xml", "0.9.1", in: store, metadata: dependency(["bigdecimal"]))
        try installFake("bigdecimal", "4.1.2", in: store, metadata: dependency([]))
        let library = GemLibrary(
            store: store, installer: GemInstaller(api: UnreachableRubyGemsAPI(), store: store))
        library.refresh()
        return library
    }

    private func gem(_ name: String, in library: GemLibrary) throws -> InstalledGem {
        try #require(library.gems.first { $0.name == name })
    }

    @Test func dependentsComeFromTheRecordedMetadata() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let library = try makeHttpartyLibrary(in: store)

        #expect(library.dependents(of: "csv") == ["httparty"])
        #expect(library.dependents(of: "bigdecimal") == ["multi_xml"])
        #expect(library.dependents(of: "httparty").isEmpty)
    }

    @Test func deletingTheRequestedGemOffersItsWholeDependencyTree() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let library = try makeHttpartyLibrary(in: store)

        let deletion = library.deletion(of: try gem("httparty", in: library))

        #expect(deletion.dependents.isEmpty)
        #expect(
            Set(deletion.orphans.map(\.name)) == ["csv", "mini_mime", "multi_xml", "bigdecimal"])
        #expect(deletion.deleteWithOrphansLabel == "Delete httparty and 4 Dependencies")
        #expect(deletion.message.contains("installed for httparty"))
    }

    @Test func aDependencyAnotherGemStillUsesIsNotOffered() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        try installFake(
            "other", "1.0.0", in: store,
            metadata: GemMetadata(requested: true, dependencies: ["csv"]))
        let library = try makeHttpartyLibrary(in: store)

        let deletion = library.deletion(of: try gem("httparty", in: library))

        #expect(!deletion.orphans.map(\.name).contains("csv"))
        #expect(deletion.orphans.map(\.name).contains("mini_mime"))
    }

    @Test func aRequestedOrUnknownDependencyIsNotOffered() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let library = try makeHttpartyLibrary(in: store)
        // mini_mime installed by name too; csv from before metadata existed.
        try GemStore.writeMetadata(
            GemMetadata(requested: true, dependencies: []),
            into: try gem("mini_mime", in: library).directoryURL)
        try FileManager.default.removeItem(
            at: try gem("csv", in: library).directoryURL.appending(component: GemMetadata.fileName))
        library.refresh()

        let names = library.deletion(of: try gem("httparty", in: library)).orphans.map(\.name)

        #expect(!names.contains("mini_mime"))
        #expect(!names.contains("csv"))
        #expect(names.contains("multi_xml"))
    }

    @Test func deletingANeededGemWarnsWhoNeedsIt() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let library = try makeHttpartyLibrary(in: store)

        let deletion = library.deletion(of: try gem("csv", in: library))

        #expect(deletion.dependents == ["httparty"])
        #expect(deletion.orphans.isEmpty)
        #expect(deletion.message.hasPrefix("httparty needs csv."))
    }

    @Test func deleteAlongWithRemovesTheOrphansToo() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let library = try makeHttpartyLibrary(in: store)
        let deletion = library.deletion(of: try gem("httparty", in: library))

        library.delete(deletion.gem, alongWith: deletion.orphans)

        #expect(library.gems.isEmpty)
        #expect(library.errorMessage == nil)
    }

    @Test func backfillRecordsDependenciesAndInfersWhatWasRequested() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        for (name, version) in [
            ("httparty", "0.22.0"), ("csv", "3.3.0"), ("mini_mime", "1.1.5"),
            ("multi_xml", "0.7.1"),
        ] {
            try installFake(name, version, in: store, metadata: nil)
        }
        let library = GemLibrary(
            store: store,
            installer: GemInstaller(
                api: StubRubyGemsAPI(catalog: Self.httpartyCatalog), store: store))
        library.refresh()

        await library.backfillMetadata()

        #expect(library.metadataByName["httparty"]?.requested == true)
        #expect(
            library.metadataByName["httparty"]?.dependencies == ["csv", "mini_mime", "multi_xml"])
        #expect(library.metadataByName["csv"] == GemMetadata(requested: false, dependencies: []))
        #expect(library.dependents(of: "multi_xml") == ["httparty"])
        // Written to disk, so the next launch doesn't ask again.
        #expect(store.metadata(for: try gem("csv", in: library)) != nil)
    }

    @Test func aFailedBackfillLeavesTheGemAloneAndShowsNoError() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        try installFake("httparty", "0.22.0", in: store, metadata: nil)
        let library = GemLibrary(
            store: store, installer: GemInstaller(api: AlwaysFailingRubyGemsAPI(), store: store))
        library.refresh()

        await library.backfillMetadata()

        #expect(library.metadataByName.isEmpty)
        #expect(library.errorMessage == nil)
    }

    @Test func aResolvedPlanCarriesEachGemsDependencies() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let library = GemLibrary(
            store: store,
            installer: GemInstaller(
                api: StubRubyGemsAPI(catalog: Self.httpartyCatalog), store: store))

        await library.prepareInstall(name: "httparty", requirement: "")

        guard case .readyToInstall(let plan, _) = library.installState else {
            Issue.record("expected .readyToInstall, got \(library.installState)")
            return
        }
        #expect(
            plan.first { $0.name == "httparty" }?.dependencies == ["csv", "mini_mime", "multi_xml"])
        #expect(plan.first { $0.name == "csv" }?.dependencies == [])
    }
}
