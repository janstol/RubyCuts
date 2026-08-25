import Foundation

/// A gem installed into the app's sandbox -- a thin wrapper around its
/// install directory, with no cached metadata, mirroring ``Script``'s
/// "thin wrapper, no cached state" shape.
///
/// The directory name is `<name>-<version>` (matching RubyGems' own
/// convention), which is also where ``name``/``version`` are read from --
/// there's no separate metadata file to go stale.
///
/// Opted out of the app target's MainActor-by-default isolation, matching
/// ``Script``: a pure value type with no actor-coupled state, so every
/// member is `nonisolated` and usable from any context, including the
/// nonisolated test target.
struct InstalledGem: Identifiable, Hashable, Sendable {
    /// The gem's install directory: `Application Support/Gems/<name>-<version>/`.
    nonisolated let directoryURL: URL

    /// Stable identity follows the directory, like ``Script``'s URL identity.
    nonisolated var id: URL { directoryURL }

    /// The gem's name, parsed from the directory name.
    nonisolated var name: String { Self.split(directoryURL.lastPathComponent).name }

    /// The installed version, parsed from the directory name.
    nonisolated var version: String { Self.split(directoryURL.lastPathComponent).version }

    /// The directory `$LOAD_PATH` should point at. Every gem's payload puts
    /// its requireable files under `lib/` -- RubyGems' own convention, and
    /// what ``GemArchive`` extracts verbatim.
    nonisolated var libURL: URL { directoryURL.appending(component: "lib") }

    nonisolated static func == (lhs: InstalledGem, rhs: InstalledGem) -> Bool {
        lhs.directoryURL == rhs.directoryURL
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(directoryURL)
    }

    /// Splits `<name>-<version>` on its last `-`. RubyGems versions only
    /// ever contain digits and dots, never `-`, so the last `-` is always
    /// the name/version boundary -- even for a hyphenated gem name like
    /// `mini-portile2`.
    nonisolated private static func split(_ dirName: String) -> (name: String, version: String) {
        guard let lastDash = dirName.lastIndex(of: "-") else {
            return (dirName, "")
        }
        let name = String(dirName[dirName.startIndex..<lastDash])
        let version = String(dirName[dirName.index(after: lastDash)...])
        return (name, version)
    }
}
