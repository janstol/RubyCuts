import Foundation
import Observation

/// Where the gems pane's install flow currently stands.
enum GemInstallState: Equatable {
    /// No install in progress.
    case idle

    /// Resolving `gem`'s dependency graph: nothing downloaded yet.
    case resolving(gem: String)

    /// `plan` is resolved and parked, waiting for the user to confirm or
    /// cancel. `requested` is the name the user actually typed, used to tell
    /// the requested gem apart from its dependencies in the plan list.
    case readyToInstall(plan: [ResolvedGem], requested: String)

    /// An install is in flight; `phase` is the step currently running.
    case installing(phase: GemInstallPhase)
}

/// Where the gems pane's live search box currently stands.
enum GemSearchState: Equatable {
    /// No query typed, or the field was just cleared.
    case idle

    /// A query is in flight.
    case searching

    /// The query resolved, possibly to no matches at all.
    case results([GemSearchResult])

    /// The request failed. Shown inline, never as a modal alert (see
    /// ``GemLibrary/search(query:)``).
    case failed(String)
}

/// The view model backing the gems sheet, mirroring ``ScriptLibrary`` exactly
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

    /// Where the install flow currently stands: resolving, parked awaiting
    /// confirmation, or actively installing. Drives the plan/progress
    /// sections and disables the install controls while ``isWorking``.
    private(set) var installState: GemInstallState = .idle

    /// Where the live search box currently stands. Drives the Results
    /// section in ``GemListView``.
    private(set) var searchState: GemSearchState = .idle

    /// Whether the install flow is doing anything right now: true while
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

    /// Also the route ``search(query:)`` takes to rubygems.org, through
    /// `installer.api`: one injected dependency rather than two, so a
    /// test's stub API backs both resolution and search.
    private let installer: GemInstaller

    init(store: GemStore = .installedGems, installer: GemInstaller = GemInstaller()) {
        self.store = store
        self.installer = installer
    }

    /// Re-reads the store and updates ``gems``. Sets ``errorMessage`` on
    /// failure instead of throwing: the list view isn't in a `throws`
    /// context.
    func refresh() {
        errorMessage = nil
        do {
            gems = try store.list()
        } catch {
            errorMessage = Self.describe(error)
            gems = []
        }
        metadataByName = Dictionary(
            gems.compactMap { gem in store.metadata(for: gem).map { (gem.name, $0) } },
            uniquingKeysWith: { first, _ in first })
    }

    /// Each installed gem's ``GemMetadata``, by gem name. A gem missing here
    /// was installed before metadata existed and hasn't been backfilled yet.
    private(set) var metadataByName: [String: GemMetadata] = [:]

    /// Whether ``backfillMetadata()`` is already running, so overlapping
    /// calls (two views' `.task`s) don't fetch twice.
    private var isBackfilling = false

    /// The installed gems that list `name` as a dependency, sorted by name.
    func dependents(of name: String) -> [String] {
        gems.map(\.name)
            .filter { $0 != name && metadataByName[$0]?.dependencies.contains(name) == true }
            .sorted()
    }

    /// What deleting `gem` would affect: the installed gems that need it,
    /// and the dependencies it leaves unused. See ``GemDeletion``.
    func deletion(of gem: InstalledGem) -> GemDeletion {
        GemDeletion(
            gem: gem, dependents: dependents(of: gem.name), orphans: orphanedDependencies(of: gem))
    }

    /// The installed dependencies that deleting `gem` would leave unused,
    /// followed transitively (httparty -> multi_xml -> bigdecimal). A gem
    /// counts only if it came in as a dependency (not requested by the
    /// user) and every installed gem that needs it is being removed too.
    /// Gems without metadata are never offered: their history is unknown.
    private func orphanedDependencies(of gem: InstalledGem) -> [InstalledGem] {
        var removing: Set<String> = [gem.name]
        var changed = true
        while changed {
            changed = false
            for candidate in gems where !removing.contains(candidate.name) {
                guard let metadata = metadataByName[candidate.name], !metadata.requested else {
                    continue
                }
                let users = dependents(of: candidate.name)
                if !users.isEmpty, users.allSatisfy(removing.contains) {
                    removing.insert(candidate.name)
                    changed = true
                }
            }
        }
        return gems.filter { $0.name != gem.name && removing.contains($0.name) }
    }

    /// Fills in ``GemMetadata`` for installed gems that have none, by asking
    /// rubygems.org for each one's dependencies once. A gem no other
    /// installed gem depends on is recorded as requested, the rest as
    /// dependencies. Best effort: a gem whose lookup fails stays without
    /// metadata and is tried again next time. Silent, since nothing the user
    /// did failed.
    func backfillMetadata() async {
        guard !isBackfilling else { return }
        let missing = gems.filter { metadataByName[$0.name] == nil }
        guard !missing.isEmpty else { return }
        isBackfilling = true
        defer { isBackfilling = false }

        var fetched: [InstalledGem: [String]] = [:]
        for gem in missing {
            guard
                let details = try? await installer.api.versionDetails(
                    ofGem: gem.name, version: gem.version)
            else { continue }
            fetched[gem] = details.dependencies.runtime.map(\.name)
        }
        guard !fetched.isEmpty else { return }

        var known = metadataByName
        for (gem, dependencies) in fetched {
            known[gem.name] = GemMetadata(requested: false, dependencies: dependencies)
        }
        for (gem, dependencies) in fetched {
            let needed = known.contains { name, metadata in
                name != gem.name && metadata.dependencies.contains(gem.name)
            }
            let metadata = GemMetadata(requested: !needed, dependencies: dependencies)
            try? GemStore.writeMetadata(metadata, into: gem.directoryURL)
        }
        refresh()
    }

    /// Resolves `name` (+ optional `requirement`, e.g. `"~> 1.0"`) into the
    /// exact set of gems an install would download, and parks the result as
    /// ``GemInstallState/readyToInstall(plan:requested:)``. Nothing is
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
    /// error this method just set, the same clobbering ``delete(_:)``
    /// avoids by returning early. Failure still re-reads ``gems`` directly
    /// (without going through `refresh()`): a download or extraction failure
    /// leaves the store untouched (``GemInstaller/install(plan:onPhase:)``
    /// stages everything first), but a local move failing during the final
    /// commit can still leave part of the plan on disk.
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

    /// Searches rubygems.org for `query`, meant to be driven by the name
    /// field's debounced `.task(id:)` rather than a button. An empty (after
    /// trimming) query resets to ``GemSearchState/idle`` without issuing a
    /// request: there's nothing to search for, and it clears stale results
    /// left over from before the field was emptied.
    ///
    /// Deliberately does not touch ``errorMessage``: that drives a modal
    /// alert, and popping one mid-typing (a typo, a dropped connection)
    /// would be hostile. A failure is shown inline instead, via
    /// ``GemSearchState/failed(_:)``.
    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchState = .idle
            return
        }
        searchState = .searching
        do {
            searchState = .results(try await installer.api.search(query: trimmed))
        } catch {
            searchState = .failed(Self.describe(error))
        }
    }

    /// Back to ``GemSearchState/idle``, called once a result is consumed
    /// into ``prepareInstall(name:requirement:)`` or the field is cleared.
    func clearSearch() {
        searchState = .idle
    }

    /// Whether `name` is already available to scripts: installed on disk
    /// or baked into the binary (see ``BundledGem``). Used to tag search
    /// results the user doesn't need to (and, for a bundled gem, can't)
    /// install.
    func isAvailable(_ name: String) -> Bool {
        gems.contains { $0.name == name } || BundledGem.all.contains { $0.name == name }
    }

    /// Deletes the gem's directory, and those of `others` (the orphaned
    /// dependencies from ``deletion(of:)``, when the user chose to remove
    /// them too), then re-lists. Stops at the first failure and sets
    /// ``errorMessage``, matching ``ScriptLibrary/delete(_:)``.
    func delete(_ gem: InstalledGem, alongWith others: [InstalledGem] = []) {
        errorMessage = nil
        do {
            for target in [gem] + others {
                try store.delete(target)
            }
        } catch {
            refresh()
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
        case .downloadTooLarge(let gem):
            let limit = ByteCountFormatter.string(
                fromByteCount: Int64(GemInstaller.maxDownloadBytes), countStyle: .memory)
            return "'\(gem)' is larger than \(limit), too large to install."
        case .invalidRequirement(let requirement):
            return
                "'\(requirement)' isn't a valid version requirement. Use a form like '~> 1.2', '>= 2.0', or an exact version such as '1.4.2', or leave it empty for the newest version."
        }
    }
}
