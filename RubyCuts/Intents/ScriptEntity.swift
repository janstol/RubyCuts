import AppIntents
import Foundation

/// The Shortcuts-picker surface for a stored ``Script``: an ``AppEntity`` whose
/// value is one row from ``ScriptStore/list()``. This is what the "Run Ruby
/// Script" intent's `@Parameter` presents: a typed, selectable script rather
/// than a free-text filename.
///
/// **Identity:** the id is the script's file name (`"hello.rb"`), resolved
/// against whichever store is current through ``script(in:)``. Not the
/// absolute file URL: that differs per device and changes when storage
/// switches between local and iCloud, while Shortcuts syncs a saved shortcut
/// across devices. A file name resolves the same everywhere. A script renamed
/// or deleted since the Shortcut was saved fails at run time with a clear
/// error, acceptable for V1.
///
/// **Isolation:** a plain `Sendable` value type (two `String`s). The
/// ``Script``/``ScriptStore`` it wraps are `nonisolated` (they opt out of the
/// app target's MainActor-default), so no actor coupling here.
struct ScriptEntity: AppEntity {
    /// The script's file name, e.g. `hello.rb`: the stable id App Intents
    /// persists in a stored Shortcut. See the type's doc comment on why it
    /// isn't the full URL.
    let id: String

    /// The script's display name (filename without `.rb`), shown in the picker.
    let name: String

    /// The ``Script`` this entity names inside `store`. `nil` if the id isn't
    /// a plain file name (one with a path in it can't have come from
    /// ``init(_:)``), so a stored id can never reach outside the store.
    func script(in store: ScriptStore) -> Script? {
        guard !id.isEmpty, (id as NSString).lastPathComponent == id, id != ".", id != ".." else {
            return nil
        }
        return Script(url: store.directoryURL.appending(component: id))
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Script"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = ScriptQuery()
}

/// The query backing ``ScriptEntity``'s picker: lists every script in
/// ``ScriptStorage/current()`` (the iCloud container when available, local
/// Documents otherwise) and resolves ids back to entities.
///
/// `Sendable` (an `EntityQuery` requirement): it holds no state. Every call
/// re-lists the directory, so there's nothing to guard.
struct ScriptQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [ScriptEntity] {
        // Filter the live directory listing by id rather than trust stored ids
        // blindly: a script referenced by an old Shortcut may have been
        // renamed or deleted. Anything not in the current listing is dropped,
        // and App Intents surfaces unresolved ids as an error to the caller.
        let listed = try await ScriptStorage.current().list().map(ScriptEntity.init)
        let listedByIds = Dictionary(uniqueKeysWithValues: listed.map { ($0.id, $0) })
        return identifiers.compactMap { listedByIds[$0] }
    }

    func suggestedEntities() async throws -> [ScriptEntity] {
        try await ScriptStorage.current().list().map(ScriptEntity.init)
    }
}

extension ScriptEntity {
    /// Convenience to build an entity straight from a ``Script``: the shape
    /// the query and tests use, kept here so callers don't repeat the
    /// file name/`name` pair.
    init(_ script: Script) {
        self.id = script.url.lastPathComponent
        self.name = script.name
    }
}
