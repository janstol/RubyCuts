import Foundation
import Observation

/// The view model backing the gems sheet -- mirrors ``ScriptLibrary`` exactly
/// (injected store, `refresh()` after every mutation, failures surfaced as
/// ``errorMessage``), with one addition: installs are async and
/// network-bound (unlike anything ``ScriptLibrary`` does), so this also
/// tracks ``isInstalling``.
///
/// MainActor isolation is implicit via the app target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, matching ``ScriptLibrary``.
@Observable
final class GemLibrary {
    /// The gems currently installed, sorted by name then version. Refreshed
    /// after every mutation so this stays in sync with disk.
    private(set) var gems: [InstalledGem] = []

    /// A message describing the last failure, shown in an alert. Cleared at
    /// the start of the next operation so a transient error doesn't linger.
    var errorMessage: String?

    /// Whether an install is currently in flight -- drives a progress
    /// indicator and disables the install control while true.
    private(set) var isInstalling = false

    private let store: GemStore
    private let installer: GemInstaller

    init(store: GemStore = .installedGems, installer: GemInstaller = GemInstaller()) {
        self.store = store
        self.installer = installer
    }

    /// Re-reads the store and updates ``gems``. Sets ``errorMessage`` on
    /// failure instead of throwing -- the list view isn't in a `throws`
    /// context.
    func refresh() {
        errorMessage = nil
        do {
            gems = try store.list()
        } catch {
            errorMessage = Self.describe(error)
            gems = []
        }
    }

    /// Resolves `name` (+ optional `requirement`, e.g. `"~> 1.0"`) and every
    /// runtime dependency it needs, downloads, verifies, and extracts each
    /// one, and re-lists. Sets ``errorMessage`` on failure; ``isInstalling``
    /// is true for the whole async operation.
    ///
    /// Success calls ``refresh()``, but failure doesn't: `refresh()` resets
    /// `errorMessage` to `nil` as its first line (so a stale error doesn't
    /// linger into the next operation), which would silently wipe out the
    /// error this method just set -- the same clobbering ``delete(_:)``
    /// avoids by returning early. Failure still re-reads ``gems`` directly
    /// (without going through `refresh()`), since a gem earlier in the
    /// install plan can have already landed on disk before a later one
    /// failed -- e.g. a checksum mismatch on the second of three resolved
    /// gems.
    func install(name: String, requirement: String) async {
        errorMessage = nil
        isInstalling = true
        defer { isInstalling = false }

        let trimmedRequirement = requirement.trimmingCharacters(in: .whitespaces)
        do {
            _ = try await installer.install(
                name: name.trimmingCharacters(in: .whitespaces),
                requirement: trimmedRequirement.isEmpty ? nil : trimmedRequirement
            )
            refresh()
        } catch {
            errorMessage = Self.describe(error)
            gems = (try? store.list()) ?? gems
        }
    }

    /// Deletes the gem's directory and re-lists. Sets ``errorMessage`` on
    /// failure, matching ``ScriptLibrary/delete(_:)``.
    func delete(_ gem: InstalledGem) {
        errorMessage = nil
        do {
            try store.delete(gem)
        } catch {
            errorMessage = Self.describe(error)
            return
        }
        refresh()
    }

    /// Maps an opaque `Error` to a short human-readable string for the alert.
    private static func describe(_ error: Error) -> String {
        if let storeError = error as? GemStoreError {
            return describe(storeError)
        }
        if let apiError = error as? RubyGemsAPIError {
            return describe(apiError)
        }
        if let resolverError = error as? GemResolverError {
            return describe(resolverError)
        }
        if let installerError = error as? GemInstallerError {
            return describe(installerError)
        }
        return error.localizedDescription
    }

    private static func describe(_ error: GemStoreError) -> String {
        switch error {
        case .alreadyInstalled(let name):
            return "\(name) is already installed. Delete it first to install a different version."
        }
    }

    private static func describe(_ error: RubyGemsAPIError) -> String {
        switch error {
        case .gemNotFound(let name):
            return "No gem named '\(name)' was found on rubygems.org."
        case .httpError(let status):
            return "rubygems.org returned an error (HTTP \(status))."
        case .decodingFailed, .invalidResponse:
            return "rubygems.org returned an unexpected response."
        }
    }

    private static func describe(_ error: GemResolverError) -> String {
        switch error {
        case .noVersionSatisfies(let gem, let requirement):
            return "No version of '\(gem)' satisfies \(requirement)."
        case .conflictingRequirements(let gem, let first, let second):
            return "'\(gem)' needs both \(first) and \(second), which can't both be satisfied."
        case .unparsableRequirement(let gem, let requirement):
            return "'\(gem)' has an unparsable version requirement: \(requirement)."
        }
    }

    private static func describe(_ error: GemInstallerError) -> String {
        switch error {
        case .checksumMismatch(let gem):
            return "'\(gem)' failed its checksum check after downloading. Try again."
        case .cExtension(let gem, _):
            return
                "'\(gem)' requires a C extension, which RubyCuts can't load. Only pure-Ruby gems are supported."
        case .archiveRejected(let gem, let detail):
            return "'\(gem)' couldn't be safely extracted: \(detail)"
        case .alreadyBundled(let gem, let version):
            return
                "'\(gem)' is built into RubyCuts (version \(version)) and doesn't need installing."
        }
    }
}
