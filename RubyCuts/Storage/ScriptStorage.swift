import Foundation

/// Where the app's scripts live right now.
nonisolated enum ScriptStorageLocation: Sendable, Equatable {
    /// The `Documents` folder of the iCloud container, shown in iCloud Drive
    /// as a "RubyCuts" folder and synced across the user's devices.
    case iCloud

    /// The sandbox's local Documents folder, used when iCloud isn't
    /// available (signed out, or iCloud Drive turned off for the app).
    case local
}

/// The outcome of ``ScriptStorage/resolve(containerLookup:)``: the store to
/// use and where it lives.
nonisolated struct ResolvedScriptStorage: Sendable {
    /// The store the app reads and writes scripts through.
    let store: ScriptStore

    /// Whether ``store`` is in iCloud or on this device only.
    let location: ScriptStorageLocation
}

/// Decides where the app's scripts live: the iCloud container when iCloud is
/// available, ``ScriptStore/local`` otherwise.
///
/// ``current()`` and ``resolved()`` resolve once and cache the result, so the
/// library, the editor and the App Intents all agree on one store. The cache
/// is dropped when the iCloud account changes (`NSUbiquityIdentityDidChange`:
/// sign-out, or iCloud Drive switched off for the app), and the next call
/// resolves again.
enum ScriptStorage {
    /// The iCloud container scripts sync through. Also named in the
    /// entitlements and in `Config/RubyCuts-Info.plist`, which makes its
    /// `Documents` folder visible in iCloud Drive.
    nonisolated static let containerIdentifier = "iCloud.dev.stol.RubyCuts"

    /// The in-flight or finished resolution, shared by every caller until
    /// ``invalidate()`` drops it.
    private static var cached: Task<ResolvedScriptStorage, Never>?

    /// The `NSUbiquityIdentityDidChange` observer that calls
    /// ``invalidate()``, registered on first use.
    private static var identityObserver: NSObjectProtocol?

    /// The store scripts should be read from and written to right now.
    static func current() async -> ScriptStore {
        await resolved().store
    }

    /// The current store together with its location. Resolves on first call
    /// and after ``invalidate()``; otherwise returns the cached result.
    static func resolved() async -> ResolvedScriptStorage {
        observeIdentityChanges()
        if let cached {
            return await cached.value
        }
        let resolution = Task { await resolve() }
        cached = resolution
        return await resolution.value
    }

    /// Drops the cached resolution so the next ``resolved()`` looks up the
    /// iCloud container again.
    static func invalidate() {
        cached = nil
    }

    /// Looks up the iCloud container and picks the store: the container's
    /// `Documents` folder when `containerLookup` returns a URL (required for
    /// the folder to be visible in iCloud Drive), ``ScriptStore/local`` when
    /// it returns `nil`.
    ///
    /// `@concurrent` because the default lookup,
    /// `FileManager.url(forUbiquityContainerIdentifier:)`, can block while it
    /// sets up the container, and must not run on the main thread.
    /// Injectable so tests can stand in a temp directory or `nil`.
    @concurrent
    nonisolated static func resolve(
        containerLookup: @Sendable () -> URL? = {
            FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)
        }
    ) async -> ResolvedScriptStorage {
        guard let container = containerLookup() else {
            return ResolvedScriptStorage(store: .local, location: .local)
        }
        let documents = container.appending(component: "Documents", directoryHint: .isDirectory)
        return ResolvedScriptStorage(store: ScriptStore(directoryURL: documents), location: .iCloud)
    }

    /// Moves every script in `source` into `destination`, renaming on a clash
    /// with the usual `-2`, `-3` suffix so nothing is overwritten. Only what
    /// ``ScriptStore/list()`` lists moves, so directories and symlinks stay
    /// put. Returns the moved scripts at their new URLs.
    ///
    /// Used once iCloud is available, to bring scripts written while it
    /// wasn't (or before this feature existed) into the synced folder. Tries
    /// every script and then throws the first failure, so one bad file
    /// doesn't strand the rest; a script that failed stays local and moves on
    /// a later attempt.
    ///
    /// `move` defaults to `FileManager.setUbiquitous(_:itemAt:destinationURL:)`,
    /// which must not run on the main thread, hence `@concurrent`. Tests pass
    /// a plain `moveItem`.
    @concurrent
    @discardableResult
    nonisolated static func moveScripts(
        from source: ScriptStore,
        into destination: ScriptStore,
        move: @Sendable (URL, URL) throws -> Void = { from, to in
            try FileManager.default.setUbiquitous(true, itemAt: from, destinationURL: to)
        }
    ) async throws -> [Script] {
        try destination.ensureDirectory()
        var moved: [Script] = []
        var firstError: Error?
        for script in try source.list() {
            let target = destination.uniqueURL(forBaseName: script.name)
            do {
                try move(script.url, target)
                moved.append(Script(url: target))
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
        return moved
    }

    /// Registers the observer that calls ``invalidate()`` when the iCloud
    /// account changes. Idempotent.
    private static func observeIdentityChanges() {
        guard identityObserver == nil else { return }
        identityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { invalidate() }
        }
    }
}
