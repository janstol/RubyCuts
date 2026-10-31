import Foundation
import Observation

/// The view model backing the script list, the project's first view model, and
/// the pattern later view models follow.
///
/// `@Observable` (the current Swift idiom; the app targets iOS 26 / macOS 26, so
/// it's available), not `ObservableObject`/`@Published`. MainActor isolation is
/// implicit via the app target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
/// no explicit `@MainActor` annotation: match the project default. Only the data
/// layer (`Script`/`ScriptStore`) opts out with `nonisolated`.
///
/// The VM owns list state only. It does **not** hold `Script` source: source
/// stays on disk and is read on demand in the editor, by design, so the editor calls `ScriptStore` directly for `source(of:)` and
/// `write`. This keeps the VM small and keeps source strings out of observable
/// list state.
///
/// Errors from the throwing `ScriptStore` methods are surfaced as
/// ``errorMessage`` (shown in an alert by the list view). After each mutation the
/// VM re-`list`s to stay consistent with disk, simpler than threading `throws`
/// through SwiftUI, and enough for the walking skeleton.
/// A hook the open editor installs so the library can flush its unsaved
/// buffer to disk before a rename moves the file out from under it.
///
/// `script` identifies which editor the hook belongs to. Under
/// `.id(selection)` SwiftUI can build the replacement editor before tearing
/// the old one down, so deregistration is identity-checked and a stale
/// teardown can't clear a registration that isn't its own.
///
/// `flush` returns whether it is safe to move the file: `false` means the
/// buffer is still unsaved and the rename must not proceed.
struct EditorSaveHook {
    let script: Script
    let flush: () -> Bool
}

@Observable
final class ScriptLibrary {
    /// The scripts currently on disk, sorted by name. Refreshed after every
    /// mutation so this stays in sync with the filesystem.
    private(set) var scripts: [Script] = []

    /// The open editor's pending-save hook, if one is registered. See
    /// ``EditorSaveHook``'s doc comment.
    private(set) var editorSaveHook: EditorSaveHook?

    /// A message describing the last failure, shown in an alert. Cleared at the
    /// start of the next operation so a transient error doesn't linger.
    var errorMessage: String?

    /// The backing store. Injectable so previews and tests can point at a temp
    /// directory. Without an injected store the library starts on
    /// ``ScriptStore/local`` and ``prepareStorage()`` swaps in whatever
    /// ``ScriptStorage`` resolves (the iCloud container when available).
    private(set) var store: ScriptStore

    /// Where ``store`` lives. `.local` until ``prepareStorage()`` resolves
    /// iCloud, and always `.local` for an injected store.
    private(set) var storageLocation: ScriptStorageLocation = .local

    /// Whether ``prepareStorage()`` resolves the store through
    /// ``ScriptStorage``. `false` when a store was injected, so tests and
    /// previews never touch the real Documents folder or iCloud.
    private let resolvesStorage: Bool

    /// Watches iCloud for changes while ``storageLocation`` is `.iCloud`.
    private var syncMonitor: ScriptSyncMonitor?

    /// The `NSUbiquityIdentityDidChange` observer that re-runs
    /// ``prepareStorage()``. Only registered when ``resolvesStorage``.
    private var identityObserver: NSObjectProtocol?

    /// How long ``prepareStorage()`` waits for iCloud's first metadata
    /// gathering before deciding about seeding. On a timeout it skips
    /// seeding for this launch rather than risk seeding on top of scripts
    /// that haven't shown up yet.
    private static let initialGatheringTimeout: Duration = .seconds(15)

    /// Where ``seedSamplesIfNeeded()`` records that seeding already happened.
    /// Injectable so tests can point at a throwaway suite instead of
    /// `.standard`, matching ``store``.
    private let defaults: UserDefaults

    /// Accessor the list view passes to the editor so both share one store. The
    /// VM doesn't expose the store publicly otherwise: source I/O belongs to
    /// the editor, not list state, but navigation needs a way to hand the same
    /// store to the destination.
    var storeForEditing: ScriptStore { store }

    /// The key ``seedSamplesIfNeeded()`` sets in ``defaults`` once it has run,
    /// so a later launch (or a user who deleted every sample) never seeds a
    /// second time.
    private static let hasSeededSampleScriptsKey = "hasSeededSampleScripts"

    /// The key ``sortOrder`` persists to in ``defaults``, mirroring
    /// ``hasSeededSampleScriptsKey``.
    private static let sortOrderKey = "scriptSortOrder"

    /// How ``scripts`` is ordered. Persisted in ``defaults`` so the choice
    /// survives relaunch, and re-applied immediately on change. Unlike
    /// ``errorMessage`` or ``scripts``, this is list *configuration*, not a
    /// snapshot of disk, so it belongs on the VM rather than the view (see
    /// `ScriptListView`'s doc comment on `newName` for the same distinction
    /// drawn the other way).
    var sortOrder: ScriptSortOrder {
        didSet {
            defaults.set(sortOrder.rawValue, forKey: Self.sortOrderKey)
            scripts = Self.sorted(scripts, by: sortOrder)
        }
    }

    /// Creates a library over `store`, or, when `store` is `nil`, over the
    /// app's real storage as resolved by ``prepareStorage()``.
    init(store: ScriptStore? = nil, defaults: UserDefaults = .standard) {
        self.store = store ?? .local
        self.resolvesStorage = store == nil
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.sortOrderKey),
            let restored = ScriptSortOrder(rawValue: raw)
        {
            sortOrder = restored
        } else {
            sortOrder = .name
        }
    }

    /// Gets the library ready to show: resolves where scripts live, moves any
    /// local scripts into iCloud, starts watching iCloud for changes, seeds
    /// the samples if this is a fresh library, and lists. Called from the
    /// list view's `.task`, and again whenever the iCloud account changes.
    ///
    /// For an injected store it only seeds and lists, as the app did before
    /// iCloud.
    ///
    /// In iCloud mode, seeding waits for the metadata query's first
    /// gathering and is skipped if that found any `.rb` items, so a new
    /// device doesn't add a second set of samples to a folder another device
    /// already filled. A device whose metadata hasn't arrived yet can still
    /// seed; the `-2` naming keeps that harmless.
    func prepareStorage() async {
        guard resolvesStorage else {
            seedSamplesIfNeeded()
            refresh()
            return
        }
        observeIdentityChanges()
        let resolved = await ScriptStorage.resolved()
        syncMonitor?.stop()
        syncMonitor = nil
        store = resolved.store
        storageLocation = resolved.location

        guard resolved.location == .iCloud else {
            seedSamplesIfNeeded()
            refresh()
            return
        }

        var moveError: Error?
        do {
            try await ScriptStorage.moveScripts(from: .local, into: resolved.store)
        } catch {
            moveError = error
        }
        let monitor = ScriptSyncMonitor { [weak self] in self?.refresh() }
        syncMonitor = monitor
        monitor.start()
        refresh()
        if let moveError {
            errorMessage = "Some scripts couldn't be moved to iCloud: \(Self.describe(moveError))"
        }

        if let gatheredCount = await monitor.waitForInitialGathering(
            timeout: Self.initialGatheringTimeout),
            syncMonitor === monitor
        {
            seedSamplesIfNeeded(gatheredScriptCount: gatheredCount)
        }
    }

    /// Re-runs ``prepareStorage()`` when the iCloud account changes
    /// (sign-out, or iCloud Drive switched off for the app). Idempotent.
    private func observeIdentityChanges() {
        guard identityObserver == nil else { return }
        identityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                ScriptStorage.invalidate()
                Task { await self?.prepareStorage() }
            }
        }
    }

    /// Re-reads the store and updates ``scripts``. Sets ``errorMessage`` on
    /// failure instead of throwing: the list view isn't in a `throws` context.
    func refresh() {
        errorMessage = nil
        do {
            scripts = Self.sorted(try store.list(), by: sortOrder)
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

    /// Installs `flush` as the pending-save hook for `script`, so a rename
    /// started elsewhere (the sidebar's context menu) can flush that
    /// editor's unsaved buffer before ``rename(_:to:)`` moves the file.
    func registerEditorSave(for script: Script, _ flush: @escaping () -> Bool) {
        editorSaveHook = EditorSaveHook(script: script, flush: flush)
    }

    /// Removes the pending-save hook for `script`, if that's still the one
    /// registered. Identity-checked rather than an unconditional clear: see
    /// ``EditorSaveHook``'s doc comment on why a stale teardown must not be
    /// able to clear a newer registration.
    func unregisterEditorSave(for script: Script) {
        guard editorSaveHook?.script == script else { return }
        editorSaveHook = nil
    }

    /// Renames the script and returns the ``Script`` at its new URL. On
    /// failure, sets ``errorMessage`` and returns `nil`; ``scripts`` is left
    /// consistent by re-`list`ing. Mirrors ``create(name:)`` exactly.
    func rename(_ script: Script, to newName: String) -> Script? {
        errorMessage = nil
        if let hook = editorSaveHook, hook.script == script, !hook.flush() {
            // The flush already reported why, through the editor's
            // `onSaveError`.
            return nil
        }
        let renamed: Script
        do {
            renamed = try store.rename(script, to: newName)
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
        refresh()
        return renamed
    }

    /// Deletes the script's file and re-lists. Sets ``errorMessage`` on failure.
    ///
    /// On failure the file wasn't removed, so `scripts` is already consistent
    /// with disk, no re-list needed, and skipping it preserves the error
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

    /// Seeds ``SampleScripts/all`` into the store on a genuinely fresh
    /// install, and never again. A no-op once ``hasSeededSampleScriptsKey``
    /// is set in ``defaults``.
    ///
    /// If the store already has scripts in it the first time this runs, it
    /// leaves them alone: seeding into a non-empty library would drop
    /// samples on top of scripts the user (or iCloud) already put there. But
    /// it still sets the flag, since "already has scripts" and "already
    /// seeded" both mean don't seed again.
    ///
    /// `gatheredScriptCount` is how many `.rb` items iCloud's metadata query
    /// knows about. Anything above zero counts as "already has scripts" even
    /// if none of them are on this device yet. Local mode passes nothing.
    ///
    /// The flag is also what makes a deleted sample stay deleted: without
    /// it, every launch would recreate whatever the user just removed.
    /// ``restoreSamples()`` is the explicit, user-initiated way back.
    func seedSamplesIfNeeded(gatheredScriptCount: Int = 0) {
        guard !defaults.bool(forKey: Self.hasSeededSampleScriptsKey) else { return }
        errorMessage = nil
        if gatheredScriptCount > 0 {
            defaults.set(true, forKey: Self.hasSeededSampleScriptsKey)
            refresh()
            return
        }
        let existing: [Script]
        do {
            existing = try store.list()
        } catch {
            errorMessage = Self.describe(error)
            return
        }
        if existing.isEmpty {
            for sample in SampleScripts.all {
                do {
                    _ = try store.create(name: sample.name, source: sample.source)
                } catch {
                    errorMessage = Self.describe(error)
                    return
                }
            }
        }
        defaults.set(true, forKey: Self.hasSeededSampleScriptsKey)
        // Refresh either way: a non-empty store never populated `scripts`
        // before this call ran (the app doesn't `refresh()` until after
        // seeding, see `ScriptListView`'s `.task`), so skipping this here
        // would leave the pre-existing scripts invisible to the list.
        refresh()
    }

    /// Re-creates every sample from ``SampleScripts/all`` that isn't already
    /// present, by name. Unlike ``seedSamplesIfNeeded()`` this always runs:
    /// it's the explicit "bring them back" action in Settings, but it
    /// skips any name already in ``scripts``, so restoring never produces a
    /// `-2` suffix via ``ScriptStore``'s collision handling.
    func restoreSamples() {
        errorMessage = nil
        let existingNames = Set(scripts.map(\.name))
        for sample in SampleScripts.all where !existingNames.contains(sample.name) {
            do {
                _ = try store.create(name: sample.name, source: sample.source)
            } catch {
                errorMessage = Self.describe(error)
                return
            }
        }
        refresh()
    }

    /// Orders `scripts` per `order`. ``ScriptStore/list()`` always returns
    /// name-sorted results, so `.name` is a no-op pass-through; `.dateModified`
    /// re-sorts newest-first, with a `nil` date sorting last (there's nothing
    /// to compare it against) and a name tiebreak so the order is total and
    /// stable rather than depending on how the store happened to enumerate.
    private static func sorted(_ scripts: [Script], by order: ScriptSortOrder) -> [Script] {
        switch order {
        case .name:
            return scripts.sorted { $0.name < $1.name }
        case .dateModified:
            return scripts.sorted { lhs, rhs in
                switch (lhs.modifiedAt, rhs.modifiedAt) {
                case (let l?, let r?) where l != r: return l > r
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.name < rhs.name
                }
            }
        }
    }

    /// Maps an opaque `Error` to a short human-readable string for the alert.
    private static func describe(_ error: Error) -> String {
        // ``ScriptStoreError`` is a `LocalizedError`, so its own messages come
        // through here too.
        error.localizedDescription
    }
}
