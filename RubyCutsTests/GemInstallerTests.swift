import CryptoKit
import Foundation
@testable import RubyCuts
import Testing

/// Serves the fixture `.gem` for every download and can fail one chosen
/// call, so a test can break an install partway through its plan. An actor
/// because the installer calls it through a `@Sendable` closure.
private actor StubGemDownloader {
    private let fixture: Data
    private var calls = 0

    /// The 1-based call that throws instead of returning the fixture, or
    /// `nil` to never fail.
    var failingCall: Int?

    init(fixture: Data, failingCall: Int? = nil) {
        self.fixture = fixture
        self.failingCall = failingCall
    }

    func download(_ url: URL) throws -> Data {
        calls += 1
        if calls == failingCall {
            throw URLError(.networkConnectionLost)
        }
        return fixture
    }

    func stopFailing() {
        failingCall = nil
    }
}

// End-to-end installs against a temp `GemStore`: real checksum
// verification and real extraction through the VM (`GemArchive.extract`),
// only the network replaced. Extraction drives `RubyRuntime.shared`, so this
// joins the `.serialized` contract under ``EmbeddedRubyTests``.
extension EmbeddedRubyTests {
    @MainActor
    @Suite(.serialized)
    struct GemInstallerTests {

        /// A parent gem with one runtime dependency. Both download the same
        /// fixture bytes, which is fine here: what matters is which
        /// `<name>-<version>` directories end up in the store.
        private static let catalog: [String: [StubRubyGemsAPI.Version]] = [
            "rc_parent": [StubRubyGemsAPI.Version("1.0.0", dependencies: [("rc_child", ">= 0")])],
            "rc_child": [StubRubyGemsAPI.Version("1.0.0")],
        ]

        private static func fixture() throws -> Data {
            try Data(
                contentsOf: EmbeddedRubyTests.GemArchiveTests.fixtureURL(
                    "rubycuts_fixture-0.0.1.gem"))
        }

        /// Runs `body` against a fresh temp `GemStore`, then removes the store
        /// and every `$LOAD_PATH` entry an install added under it, whether `body`
        /// passed or threw. The VM is shared, so a leftover entry would break
        /// `RubyRuntimeTests.loadPathIsExactlyTheBundledStdlibPlusAnyInstalledGems`.
        private static func withTempStore(_ body: (GemStore) async throws -> Void) async throws {
            let store = GemStore(
                directoryURL: FileManager.default.temporaryDirectory
                    .appending(component: "RubyCutsTests-installer-\(UUID().uuidString)"))
            try store.ensureDirectory()
            do {
                try await body(store)
            } catch {
                await cleanUp(store)
                throw error
            }
            await cleanUp(store)
        }

        private static func cleanUp(_ store: GemStore) async {
            try? FileManager.default.removeItem(at: store.directoryURL)
            let root = RubyRuntime.base64(store.directoryURL.path)
            _ = try? await RubyRuntime.shared.evaluate(
                "require 'base64'; root = Base64.decode64(\"\(root)\"); "
                    + "$LOAD_PATH.reject! { |p| p.start_with?(root) }; nil")
        }

        private static func makeInstaller(
            store: GemStore, downloader: StubGemDownloader, fixture: Data
        ) -> GemInstaller {
            let sha = SHA256.hash(data: fixture).map { String(format: "%02x", $0) }.joined()
            return GemInstaller(
                api: StubRubyGemsAPI(catalog: catalog, sha256: sha),
                store: store,
                download: { try await downloader.download($0) }
            )
        }

        @Test func aFailedDownloadLeavesTheStoreUntouchedAndARetrySucceeds() async throws {
            let fixture = try Self.fixture()
            try await Self.withTempStore { store in
                let downloader = StubGemDownloader(fixture: fixture, failingCall: 2)
                let installer = Self.makeInstaller(
                    store: store, downloader: downloader, fixture: fixture)

                let plan = try await installer.plan(name: "rc_parent", requirement: nil)
                #expect(plan.map(\.name) == ["rc_parent", "rc_child"])

                await #expect(throws: URLError.self) {
                    try await installer.install(plan: plan) { _ in }
                }
                // The parent downloaded fine before the child failed, but nothing
                // was committed, so it isn't sitting there without its dependency.
                #expect(try store.list().isEmpty)

                await downloader.stopFailing()
                let retryPlan = try await installer.plan(name: "rc_parent", requirement: nil)
                #expect(retryPlan.map(\.name) == ["rc_parent", "rc_child"])
                let installed = try await installer.install(plan: retryPlan) { _ in }
                #expect(installed.map(\.name) == ["rc_parent", "rc_child"])
                #expect(try store.list().map(\.name) == ["rc_child", "rc_parent"])
            }
        }

        @Test func reinstallingAParentRestoresADeletedDependency() async throws {
            let fixture = try Self.fixture()
            try await Self.withTempStore { store in
                let downloader = StubGemDownloader(fixture: fixture)
                let installer = Self.makeInstaller(
                    store: store, downloader: downloader, fixture: fixture)
                let library = GemLibrary(store: store, installer: installer)

                await library.prepareInstall(name: "rc_parent", requirement: "")
                await library.confirmInstall()
                #expect(library.gems.map(\.name) == ["rc_child", "rc_parent"])

                let child = try #require(library.gems.first { $0.name == "rc_child" })
                library.delete(child)
                #expect(library.gems.map(\.name) == ["rc_parent"])

                await library.prepareInstall(name: "rc_parent", requirement: "")
                #expect(library.errorMessage == nil)
                guard case .readyToInstall(let plan, _) = library.installState else {
                    Issue.record("expected a parked plan, got \(library.installState)")
                    return
                }
                #expect(plan.map(\.name) == ["rc_child"])

                await library.confirmInstall()
                #expect(library.errorMessage == nil)
                #expect(library.gems.map(\.name) == ["rc_child", "rc_parent"])
            }
        }

        @Test func aGemAlreadyOnDiskIsRejectedBeforeAnythingDownloads() async throws {
            let fixture = try Self.fixture()
            try await Self.withTempStore { store in
                let downloader = StubGemDownloader(fixture: fixture, failingCall: 1)
                let installer = Self.makeInstaller(
                    store: store, downloader: downloader, fixture: fixture)

                let plan = try await installer.plan(name: "rc_child", requirement: nil)
                try FileManager.default.createDirectory(
                    at: store.destinationURL(name: "rc_child", version: "0.9.0"),
                    withIntermediateDirectories: true)

                // The downloader would throw URLError on its first call; getting
                // alreadyInstalled instead proves validation ran first.
                await #expect(throws: GemStoreError.alreadyInstalled("rc_child")) {
                    try await installer.install(plan: plan) { _ in }
                }
            }
        }

        @Test func anOversizedDownloadIsRefusedAndNothingIsInstalled() async throws {
            let fixture = try Self.fixture()
            try await Self.withTempStore { store in
                let downloader = StubGemDownloader(fixture: fixture)
                let sha = SHA256.hash(data: fixture).map { String(format: "%02x", $0) }.joined()
                let installer = GemInstaller(
                    api: StubRubyGemsAPI(catalog: Self.catalog, sha256: sha),
                    store: store,
                    download: { try await downloader.download($0) },
                    maxDownloadBytes: fixture.count - 1
                )
                let plan = try await installer.plan(name: "rc_parent", requirement: nil)

                do {
                    _ = try await installer.install(plan: plan) { _ in }
                    Issue.record("expected the install to fail")
                } catch GemInstallerError.downloadTooLarge(let gem) {
                    #expect(gem == "rc_parent")
                }
                #expect(try store.list().isEmpty)
            }
        }

        @Test func anInstallRecordsWhichGemWasRequested() async throws {
            let fixture = try Self.fixture()
            try await Self.withTempStore { store in
                let downloader = StubGemDownloader(fixture: fixture)
                let installer = Self.makeInstaller(
                    store: store, downloader: downloader, fixture: fixture)
                let plan = try await installer.plan(name: "rc_parent", requirement: nil)

                let installed = try await installer.install(plan: plan) { _ in }

                let parent = try #require(installed.first { $0.name == "rc_parent" })
                let child = try #require(installed.first { $0.name == "rc_child" })
                #expect(
                    store.metadata(for: parent)
                        == GemMetadata(requested: true, dependencies: ["rc_child"]))
                #expect(
                    store.metadata(for: child) == GemMetadata(requested: false, dependencies: []))
            }
        }
    }
}
