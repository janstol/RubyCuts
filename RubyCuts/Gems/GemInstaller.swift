import CryptoKit
import Foundation

/// An error raised while installing a gem through ``GemInstaller``.
enum GemInstallerError: Error, Sendable {
    /// The downloaded bytes' SHA-256 didn't match what rubygems.org reported
    /// for this version. Refuse to extract a payload that doesn't match
    /// its own advertised checksum.
    case checksumMismatch(gem: String)

    /// The gem (or a dependency) contains a C extension, discovered only
    /// after downloading and extracting: the v2 API doesn't reliably
    /// expose `extensions`, so this can't be caught during resolution.
    case cExtension(gem: String, detail: String)

    /// The archive itself was rejected as unsafe (a path escape, a
    /// symlink/hardlink, or a malformed `.gem`).
    case archiveRejected(gem: String, detail: String)

    /// The gem requested at the top level is already baked into the app
    /// (see ``BundledGem``): installing it would be a silent no-op at
    /// best, so this is raised instead of quietly resolving to nothing. A
    /// gem depended on *transitively* isn't affected: ``GemResolver``
    /// already treats it as satisfied via the seed in
    /// ``GemInstaller/installedVersionsByName()``.
    case alreadyBundled(gem: String, version: String)
}

/// One step of an in-flight install, reported to the caller as it begins.
///
/// `index` is 0-based (the gem's position in the resolved plan); `label`
/// renders it 1-based for display.
enum GemInstallPhase: Equatable, Sendable {
    /// Downloading and checksumming the gem at `index` (of `total`) in the
    /// plan.
    case downloading(gem: String, index: Int, total: Int)

    /// Extracting the gem at `index` (of `total`) in the plan into the VM's
    /// gem store.
    case extracting(gem: String, index: Int, total: Int)

    /// A short human-readable label for this phase, e.g.
    /// `"Downloading csv (2 of 4)"` or `"Extracting csv (2 of 4)"`.
    var label: String {
        switch self {
        case .downloading(let gem, let index, let total):
            return "Downloading \(gem) (\(index + 1) of \(total))"
        case .extracting(let gem, let index, let total):
            return "Extracting \(gem) (\(index + 1) of \(total))"
        }
    }

    /// This phase's progress through the whole plan, in `0...1`. Downloading
    /// a gem accounts for the first half of its slice and extracting it the
    /// second half, so a determinate progress bar advances twice per gem.
    var fractionCompleted: Double {
        switch self {
        case .downloading(_, let index, let total):
            return Double(index) / Double(total)
        case .extracting(_, let index, let total):
            return (Double(index) + 0.5) / Double(total)
        }
    }
}

/// Orchestrates a gem install end to end: resolve dependencies, download and
/// verify each `.gem`, extract it, move it into ``GemStore``, and append its
/// `lib/` directory to `$LOAD_PATH` immediately, so the gem is requireable
/// without an app restart. (``RubyRuntime/bootIfNeeded()`` does the same
/// append at boot for gems installed in a previous run.)
///
/// The type itself is on the main actor; extraction hops onto ``RubyRuntime``'s
/// dedicated VM thread through ``GemArchive/extract(gemFileURL:destination:)``,
/// which is `async`.
@MainActor
struct GemInstaller {
    let api: RubyGemsAPI
    let store: GemStore
    private let session: URLSession

    init(
        api: RubyGemsAPI = LiveRubyGemsAPI(),
        store: GemStore = .installedGems,
        session: URLSession = .shared
    ) {
        self.api = api
        self.store = store
        self.session = session
    }

    /// Resolves `name` (optionally pinned by `requirement`, e.g. `"~> 1.0"`)
    /// into the exact set of gems an install would download: `name` itself
    /// plus every runtime dependency it needs that isn't already installed.
    /// Nothing is downloaded or written to disk; this is the preview half of
    /// the two-step install flow, letting the caller show the plan before
    /// committing to it.
    func plan(name: String, requirement: String?) async throws -> [ResolvedGem] {
        if let bundled = BundledGem.all.first(where: { $0.name == name }) {
            throw GemInstallerError.alreadyBundled(gem: bundled.name, version: bundled.version)
        }

        let parsedRequirement = requirement.flatMap { GemRequirement($0) }
        let installedVersions = try installedVersionsByName()

        let resolver = GemResolver(api: api)
        return try await resolver.resolve(
            name: name, requirement: parsedRequirement, installed: installedVersions
        )
    }

    /// Downloads, verifies, extracts, and installs every gem in `plan`, in
    /// order, reporting each phase to `onPhase` as it begins. Returns the
    /// gems this call actually installed.
    ///
    /// `onPhase` is called synchronously on the main actor: `GemInstaller`
    /// is `@MainActor`, so no `@Sendable` or actor hop is needed here.
    func install(
        plan: [ResolvedGem], onPhase: (GemInstallPhase) -> Void
    ) async throws -> [InstalledGem] {
        var installed: [InstalledGem] = []
        for (index, target) in plan.enumerated() {
            installed.append(
                try await installOne(target, index: index, total: plan.count, onPhase: onPhase)
            )
        }
        return installed
    }

    /// Everything ``GemResolver`` should treat as already satisfied: every
    /// ``BundledGem`` (seeded first, so a gem depending on `sqlite3`
    /// resolves without a download) overlaid with whatever ``GemStore``
    /// actually has on disk.
    private func installedVersionsByName() throws -> [String: GemVersion] {
        var result: [String: GemVersion] = BundledGem.all.reduce(into: [:]) { result, bundled in
            if let version = GemVersion(bundled.version) {
                result[bundled.name] = version
            }
        }
        for gem in try store.list() {
            if let version = GemVersion(gem.version) {
                result[gem.name] = version
            }
        }
        return result
    }

    private func installOne(
        _ target: ResolvedGem, index: Int, total: Int, onPhase: (GemInstallPhase) -> Void
    ) async throws -> InstalledGem {
        onPhase(.downloading(gem: target.name, index: index, total: total))
        let (data, _) = try await session.data(from: target.downloadURL)
        try Self.verifyChecksum(data, expectedHex: target.sha256, gemName: target.name)

        let tempRoot = FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsGemInstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let gemFileURL = tempRoot.appending(component: "\(target.name).gem")
        try data.write(to: gemFileURL)

        let extractedURL = tempRoot.appending(component: "extracted")
        onPhase(.extracting(gem: target.name, index: index, total: total))
        do {
            try await GemArchive.extract(gemFileURL: gemFileURL, destination: extractedURL)
        } catch GemArchiveError.containsCExtension(let detail) {
            throw GemInstallerError.cExtension(gem: target.name, detail: detail)
        } catch GemArchiveError.unsafeArchive(let detail) {
            throw GemInstallerError.archiveRejected(gem: target.name, detail: detail)
        }

        let gem = try store.install(
            from: extractedURL, name: target.name, version: target.version.raw
        )
        await RubyRuntime.shared.appendLoadPath(gem.libURL)
        return gem
    }

    private static func verifyChecksum(_ data: Data, expectedHex: String, gemName: String) throws {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex.caseInsensitiveCompare(expectedHex) == .orderedSame else {
            throw GemInstallerError.checksumMismatch(gem: gemName)
        }
    }
}
