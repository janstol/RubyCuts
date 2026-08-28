import Foundation
import Observation

/// Where the gems pane's install flow currently stands.
enum GemInstallState: Equatable {
    /// No install in progress.
    case idle

    /// Resolving `gem`'s dependency graph -- nothing downloaded yet.
    case resolving(gem: String)

    /// `plan` is resolved and parked, waiting for the user to confirm or
    /// cancel. `requested` is the name the user actually typed, used to tell
    /// the requested gem apart from its dependencies in the plan list.
    case readyToInstall(plan: [ResolvedGem], requested: String)

    /// An install is in flight; `phase` is the step currently running.
    case installing(phase: GemInstallPhase)
}

/// The view model backing the gems sheet -- mirrors ``ScriptLibrary`` exactly
/// (injected store, `refresh()` after every mutation, failures surfaced as
/// ``errorMessage``), with one addition: installs are async and
/// network-bound (unlike anything ``ScriptLibrary`` does), so this also
/// tracks ``installState``.
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

    /// Where the install flow currently stands -- resolving, parked awaiting
    /// confirmation, or actively installing. Drives the plan/progress
    /// sections and disables the install controls while ``isWorking``.
    private(set) var installState: GemInstallState = .idle

    /// Whether the install flow is doing anything right now -- true while
    /// resolving or installing, false while idle or parked at
    /// `.readyToInstall` (which is waiting on the user, not working).
    var isWorking: Bool {
        switch installState {
        case .resolving, .installing:
            return true
        case .idle, .readyToInstall:
            return false
        }
    }

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

    /// Resolves `name` (+ optional `requirement`, e.g. `"~> 1.0"`) into the
    /// exact set of gems an install would download, and parks the result as
    /// ``GemInstallState/readyToInstall(plan:requested:)`` -- nothing is
    /// downloaded here. Sets ``errorMessage`` on failure, or on an empty
    /// plan (`name` is already installed), and returns to ``.idle`` either
    /// way.
    func prepareInstall(name: String, requirement: String) async {
        errorMessage = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedRequirement = requirement.trimmingCharacters(in: .whitespaces)
        installState = .resolving(gem: trimmedName)

        do {
            let plan = try await installer.plan(
                name: trimmedName,
                requirement: trimmedRequirement.isEmpty ? nil : trimmedRequirement
            )
            if plan.isEmpty {
                errorMessage = "'\(trimmedName)' is already installed."
                installState = .idle
            } else {
                installState = .readyToInstall(plan: plan, requested: trimmedName)
            }
        } catch {
            errorMessage = Self.describe(error)
            installState = .idle
        }
    }

    /// Downloads, verifies, extracts, and installs the plan parked by
    /// ``prepareInstall(name:requirement:)``. A no-op if nothing is parked.
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
    func confirmInstall() async {
        guard case .readyToInstall(let plan, _) = installState else { return }
        errorMessage = nil
        defer { installState = .idle }

        do {
            _ = try await installer.install(plan: plan) { phase in
                installState = .installing(phase: phase)
            }
            refresh()
        } catch {
            errorMessage = Self.describe(error)
            gems = (try? store.list()) ?? gems
        }
    }

    /// Drops a plan parked by ``prepareInstall(name:requirement:)`` back to
    /// ``.idle`` without installing anything.
    func cancelPendingInstall() {
        installState = .idle
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
