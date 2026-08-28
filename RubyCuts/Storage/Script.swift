import Foundation

/// A Ruby script file on disk -- a thin wrapper around its file URL, with no
/// SwiftData and no cached contents.
///
/// The model is deliberately just a URL plus cheap filesystem metadata: a
/// script file can be large, so source is read on demand through
/// ``ScriptStore`` rather than held here -- that's the line, not "no fields
/// beyond the URL". ``modifiedAt`` earns its place because ``ScriptStore/list()``
/// already has it in hand from the directory scan that produces every
/// ``Script`` in the first place, so it costs nothing extra to carry.
/// `Identifiable` (via ``id``) lets Phase 3 list views use `ForEach(scripts)`;
/// `Hashable` and `Sendable` come for free from `URL`.
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

    /// When the file was last written, as reported by the filesystem at the
    /// time this ``Script`` was listed. `nil` if the metadata couldn't be
    /// read (the row falls back to name only rather than failing the whole
    /// listing over it). Deliberately excluded from ``==``/``hash(into:)``:
    /// see those witnesses' doc comments.
    nonisolated let modifiedAt: Date?

    /// The URL itself -- two `Script`s are the same script iff they point at the
    /// same file.
    nonisolated var id: URL { url }

    /// The script's display name: the filename without its `.rb` extension.
    nonisolated var name: String { url.deletingPathExtension().lastPathComponent }

    nonisolated init(url: URL, modifiedAt: Date? = nil) {
        self.url = url
        self.modifiedAt = modifiedAt
    }

    /// Identity is "which file", not "what state": two `Script`s that point
    /// at the same URL are equal even if their ``modifiedAt`` differs. This
    /// is what keeps `List(selection:)` highlighting and `.id(selection)`
    /// stable across a metadata-only refresh -- a refresh after a save
    /// returns a `Script` for the same file with a newer date, and it must
    /// compare equal to the one already selected, or the detail view would
    /// tear down and rebuild mid-edit.
    nonisolated static func == (lhs: Script, rhs: Script) -> Bool {
        lhs.url == rhs.url
    }

    /// Combines only ``url``, matching ``==`` -- see its doc comment. Two
    /// equal `Script`s must hash the same, so `modifiedAt` can't be folded in
    /// here either.
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
