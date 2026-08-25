import CryptoKit
import Foundation

/// An error raised while installing a gem through ``GemInstaller``.
enum GemInstallerError: Error, Sendable {
    /// The downloaded bytes' SHA-256 didn't match what rubygems.org reported
    /// for this version -- refuse to extract a payload that doesn't match
    /// its own advertised checksum.
    case checksumMismatch(gem: String)

    /// The gem (or a dependency) contains a C extension, discovered only
    /// after downloading and extracting -- the v2 API doesn't reliably
    /// expose `extensions`, so this can't be caught during resolution.
    case cExtension(gem: String, detail: String)

    /// The archive itself was rejected as unsafe (a path escape, a
    /// symlink/hardlink, or a malformed `.gem`).
    case archiveRejected(gem: String, detail: String)
}

/// Orchestrates a gem install end to end: resolve dependencies, download and
/// verify each `.gem`, extract it, move it into ``GemStore``, and append its
/// `lib/` directory to `$LOAD_PATH` immediately -- so the gem is requireable
/// without an app restart. (``RubyRuntime/bootIfNeeded()`` does the same
/// append at boot for gems installed in a previous run.)
///
/// Runs on the main actor: extraction goes through ``GemArchive``, which
/// drives the `@MainActor`-pinned ``RubyRuntime``.
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

    /// Installs `name` (optionally pinned by `requirement`, e.g. `"~> 1.0"`)
    /// and every runtime dependency it needs that isn't already installed.
    /// Returns the gems this call actually installed -- an already-satisfied
    /// dependency (per ``GemResolver``) is skipped and doesn't appear here.
    func install(name: String, requirement: String?) async throws -> [InstalledGem] {
        let parsedRequirement = requirement.flatMap { GemRequirement($0) }
        let installedVersions = try installedVersionsByName()

        let resolver = GemResolver(api: api)
        let plan = try await resolver.resolve(
            name: name, requirement: parsedRequirement, installed: installedVersions
        )

        var installed: [InstalledGem] = []
        for target in plan {
            installed.append(try await installOne(target))
        }
        return installed
    }

    private func installedVersionsByName() throws -> [String: GemVersion] {
        try store.list().reduce(into: [:]) { result, gem in
            if let version = GemVersion(gem.version) {
                result[gem.name] = version
            }
        }
    }

    private func installOne(_ target: ResolvedGem) async throws -> InstalledGem {
        let (data, _) = try await session.data(from: target.downloadURL)
        try Self.verifyChecksum(data, expectedHex: target.sha256, gemName: target.name)

        let tempRoot = FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsGemInstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let gemFileURL = tempRoot.appending(component: "\(target.name).gem")
        try data.write(to: gemFileURL)

        let extractedURL = tempRoot.appending(component: "extracted")
        do {
            try GemArchive.extract(gemFileURL: gemFileURL, destination: extractedURL)
        } catch GemArchiveError.containsCExtension(let detail) {
            throw GemInstallerError.cExtension(gem: target.name, detail: detail)
        } catch GemArchiveError.unsafeArchive(let detail) {
            throw GemInstallerError.archiveRejected(gem: target.name, detail: detail)
        }

        let gem = try store.install(
            from: extractedURL, name: target.name, version: target.version.raw
        )
        RubyRuntime.shared.appendLoadPath(gem.libURL)
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
