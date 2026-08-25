import Foundation

/// An error raised while managing gems through ``GemStore``.
enum GemStoreError: Error, Sendable, Equatable {
    /// A gem with this name (any version) is already installed. V1 doesn't
    /// support side-by-side versions or upgrading in place -- delete the
    /// existing install first.
    case alreadyInstalled(String)
}

/// A value-type store over a directory of installed gems -- the
/// ``ScriptStore`` pattern applied to gems instead of scripts: one
/// subdirectory per gem, named `<name>-<version>`.
///
/// Gems live in **Application Support**, not Documents: Documents is the
/// user's script folder and the designed iCloud swap point
/// (``ScriptStore/userScripts``), and gem payloads do not belong there and
/// must not sync.
///
/// `Sendable`, and every member `nonisolated`, matching ``ScriptStore``: the
/// only stored state is a `let directoryURL`, so there's no in-process state
/// to guard.
struct GemStore: Sendable {
    /// The directory this store reads and writes.
    nonisolated let directoryURL: URL

    /// The app's gem store: `Application Support/Gems`.
    nonisolated static var installedGems: GemStore {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return GemStore(directoryURL: appSupport.appending(component: "Gems"))
    }

    /// Creates the backing directory if it doesn't exist. Idempotent.
    nonisolated func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    /// Lists every installed gem, sorted by name then version. Uses
    /// `contentsOfDirectory` (not a recursive enumerator), matching
    /// ``ScriptStore/list()`` -- one directory per gem, no nesting to walk.
    nonisolated func list() throws -> [InstalledGem] {
        try ensureDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil
        )
        let directories = urls.filter(Self.isDirectory)
        let gems = directories.map(InstalledGem.init)
        return gems.sorted(by: Self.byNameThenVersion)
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    nonisolated private static func byNameThenVersion(_ lhs: InstalledGem, _ rhs: InstalledGem)
        -> Bool
    {
        lhs.name == rhs.name ? lhs.version < rhs.version : lhs.name < rhs.name
    }

    /// Whether any version of `name` is currently installed.
    nonisolated func isInstalled(_ name: String) throws -> Bool {
        try list().contains { $0.name == name }
    }

    /// The directory a fresh install of `name`/`version` belongs at. Doesn't
    /// create it -- ``GemInstaller`` extracts into a temp directory first and
    /// moves it here only on success, so a failed or interrupted install
    /// never leaves a half-extracted gem that `$LOAD_PATH` would pick up.
    ///
    /// `directoryHint: .isDirectory` matters here: without it, this URL
    /// carries no trailing slash while `list()`'s `contentsOfDirectory`
    /// entries for the same path do, which makes an `InstalledGem` built
    /// from this URL compare unequal (`URL`'s `==`) to the one `list()`
    /// reads back after the install.
    nonisolated func destinationURL(name: String, version: String) -> URL {
        directoryURL.appending(component: "\(name)-\(version)", directoryHint: .isDirectory)
    }

    /// Moves an already-extracted gem directory into place. Throws
    /// ``GemStoreError/alreadyInstalled(_:)`` if `name` is already installed
    /// at any version.
    nonisolated func install(from extractedURL: URL, name: String, version: String) throws
        -> InstalledGem
    {
        try ensureDirectory()
        if try isInstalled(name) {
            throw GemStoreError.alreadyInstalled(name)
        }
        let target = destinationURL(name: name, version: version)
        try FileManager.default.moveItem(at: extractedURL, to: target)
        return InstalledGem(directoryURL: target)
    }

    /// Deletes the gem's directory from disk.
    nonisolated func delete(_ gem: InstalledGem) throws {
        try FileManager.default.removeItem(at: gem.directoryURL)
    }
}
