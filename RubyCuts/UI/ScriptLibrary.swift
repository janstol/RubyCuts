import Foundation
import Observation

/// The view model backing the script list -- the project's first view model, and
/// the pattern Phase 3's editor/console VMs and Phase 5's intents should follow.
///
/// `@Observable` (the current Swift idiom; the app targets iOS 18 / macOS 15, so
/// it's available) -- not `ObservableObject`/`@Published`. MainActor isolation is
/// implicit via the app target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
/// no explicit `@MainActor` annotation: match the project default. Only the data
/// layer (`Script`/`ScriptStore`) opts out with `nonisolated`.
///
/// The VM owns list state only. It does **not** hold `Script` source -- source
/// stays on disk and is read on demand in the editor, exactly as Phase 2
/// designed -- so the editor calls `ScriptStore` directly for `source(of:)` and
/// `write`. This keeps the VM small and keeps source strings out of observable
/// list state.
///
/// Errors from the throwing `ScriptStore` methods are surfaced as
/// ``errorMessage`` (shown in an alert by the list view). After each mutation the
/// VM re-`list`s to stay consistent with disk -- simpler than threading `throws`
/// through SwiftUI, and enough for the walking skeleton.
@Observable
final class ScriptLibrary {
    /// The scripts currently on disk, sorted by name. Refreshed after every
    /// mutation so this stays in sync with the filesystem.
    private(set) var scripts: [Script] = []

    /// A message describing the last failure, shown in an alert. Cleared at the
    /// start of the next operation so a transient error doesn't linger.
    var errorMessage: String?

    /// The backing store. Injectable so previews and tests can point at a temp
    /// directory instead of the real sandbox Documents dir.
    private let store: ScriptStore

    /// Accessor the list view passes to the editor so both share one store. The
    /// VM doesn't expose the store publicly otherwise -- source I/O belongs to
    /// the editor, not list state -- but navigation needs a way to hand the same
    /// store to the destination.
    var storeForEditing: ScriptStore { store }

    init(store: ScriptStore = .userScripts) {
        self.store = store
    }

    /// Re-reads the store and updates ``scripts``. Sets ``errorMessage`` on
    /// failure instead of throwing -- the list view isn't in a `throws` context.
    func refresh() {
        errorMessage = nil
        do {
            scripts = try store.list()
        } catch {
            errorMessage = Self.describe(error)
            scripts = []
        }
    }

    /// Creates a script with empty source and returns it so the list view can
    /// navigate to the editor for it. On failure, sets ``errorMessage`` and
    /// returns `nil`; ``scripts`` is left consistent by re-`list`ing.
    func create(name: String) -> Script? {
        errorMessage = nil
        let script: Script
        do {
            script = try store.create(name: name, source: "")
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
        // Re-list rather than optimistically appending: the store may have
        // applied a collision suffix (e.g. `Untitled-2`), and we want the
        // returned script and the list to agree with what's on disk.
        refresh()
        return script
    }

    /// Deletes the script's file and re-lists. Sets ``errorMessage`` on failure.
    ///
    /// On failure the file wasn't removed, so `scripts` is already consistent
    /// with disk -- no re-list needed, and skipping it preserves the error
    /// (a `refresh()` would clear `errorMessage`). On success the deleted
    /// script is gone from disk, so re-list to drop it from `scripts`.
    func delete(_ script: Script) {
        errorMessage = nil
        do {
            try store.delete(script)
        } catch {
            errorMessage = Self.describe(error)
            return
        }
        refresh()
    }

    /// Maps an opaque `Error` to a short human-readable string for the alert.
    private static func describe(_ error: Error) -> String {
        if let storeError = error as? ScriptStoreError {
            switch storeError {
            case .invalidName: return "The script name can't be empty."
            }
        }
        return error.localizedDescription
    }
}
