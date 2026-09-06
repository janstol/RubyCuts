import AppIntents
import Foundation

/// The Shortcuts-picker surface for a stored ``Script``: an ``AppEntity`` whose
/// value is one row from ``ScriptStore/list()``. This is what the "Run Ruby
/// Script" intent's `@Parameter` presents: a typed, selectable script rather
/// than a free-text filename.
///
/// **Identity:** the App Intents framework only accepts `String`, `UUID`,
/// `Int`, `Float`, or `FileEntityIdentifier` as an entity id (see
/// `EntityIdentifierConvertible`); `URL` itself does not conform. So the id is
/// the script file URL's absolute string, which round-trips back to a `URL`
/// (and thus to a ``Script``) through ``script``. That is stable enough for V1:
/// the file URL doesn't move unless the script is renamed/moved on disk, in
/// which case a stored Shortcut referencing it will fail at run time with a
/// clear "script not found", acceptable, and noted in the PRD.
///
/// **Isolation:** a plain `Sendable` value type (two `String`s). The
/// ``Script``/``ScriptStore`` it wraps are `nonisolated` (they opt out of the
/// app target's MainActor-default), and ``ScriptQuery`` calls them from a
/// `Sendable` `EntityQuery`, so no actor coupling here.
struct ScriptEntity: AppEntity {
    /// The script file URL's absolute string: the stable id App Intents
    /// persists in a stored Shortcut. See the class doc on why this is a
    /// `String` and not a `URL`.
    let id: String

    /// The script's display name (filename without `.rb`), shown in the picker.
    let name: String

    /// Reconstructs the ``Script`` this entity points at, for
    /// ``ScriptStore/source(of:)``. The id always came from a real file URL, so
    /// the `URL(string:)` parse can't fail in practice; the guard makes that
    /// explicit rather than force-unwrapping.
    var script: Script? {
        guard let url = URL(string: id) else { return nil }
        return Script(url: url)
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Script"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = ScriptQuery()
}

/// The query backing ``ScriptEntity``'s picker: lists every script in
/// ``ScriptStore/userScripts`` (the app's Documents directory today, the iCloud
/// swap point later) and resolves ids back to entities.
///
/// `Sendable` (an `EntityQuery` requirement): it holds no state. Every call
/// re-lists the directory, so there's nothing to guard. ``ScriptStore/list()``
/// is `nonisolated` and fast for small dirs, so these async entry points just
/// bridge to it.
struct ScriptQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [ScriptEntity] {
        // Filter the live directory listing by id rather than trust stored ids
        // blindly: a script referenced by an old Shortcut may have been
        // renamed or deleted. Anything not in the current listing is dropped,
        // and App Intents surfaces unresolved ids as an error to the caller.
        let listed = try ScriptStore.userScripts.list()
        let listedByIds = Dictionary(
            uniqueKeysWithValues: listed.map { ($0.id.absoluteString, $0) })
        return identifiers.compactMap { listedByIds[$0] }.map(ScriptEntity.init)
    }

    func suggestedEntities() async throws -> [ScriptEntity] {
        try ScriptStore.userScripts.list().map(ScriptEntity.init)
    }
}

extension ScriptEntity {
    /// Convenience to build an entity straight from a ``Script``: the shape
    /// the query and tests use, kept here so callers don't repeat the
    /// `absoluteString`/`name` pair.
    init(_ script: Script) {
        self.id = script.url.absoluteString
        self.name = script.name
    }
}
