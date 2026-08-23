import Foundation

/// A Ruby script file on disk -- a thin wrapper around its file URL, with no
/// SwiftData and no cached contents.
///
/// The model is deliberately just a URL: a script file can be large, so source
/// is read on demand through ``ScriptStore`` rather than held here. There are no
/// speculative fields (no creation date, no cached source). `Identifiable` (via
/// ``id``) lets Phase 3 list views use `ForEach(scripts)`; `Hashable` and
/// `Sendable` come for free from `URL`.
///
/// Opted out of the app target's MainActor-by-default isolation (see
/// `SWIFT_DEFAULT_ACTOR_ISOLATION` in `project.pbxproj`): this is a pure value
/// type with no actor-coupled state, so it's `nonisolated` and usable from any
/// context -- including the nonisolated test target and, later, background I/O.
/// The `Equatable`/`Hashable` witnesses are written out (not synthesized)
/// because synthesis would inherit the type's MainActor isolation and make `==`
/// unusable off the main actor -- exactly what the tests need to do.
struct Script: Identifiable, Hashable, Sendable {
    /// The file URL the script lives at. Stable identity follows the file: rename
    /// moves the URL, so the identity moves with it.
    nonisolated let url: URL

    /// The URL itself -- two `Script`s are the same script iff they point at the
    /// same file.
    nonisolated var id: URL { url }

    /// The script's display name: the filename without its `.rb` extension.
    nonisolated var name: String { url.deletingPathExtension().lastPathComponent }

    nonisolated static func == (lhs: Script, rhs: Script) -> Bool {
        lhs.url == rhs.url
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
