import SwiftUI

/// An install form (name + optional version requirement) and the list of
/// installed gems, with delete. Content-only: no navigation chrome, dismiss
/// button, or sizing frame of its own: it's hosted by ``SettingsView`` on
/// iOS/iPadOS and by ``GemSettingsPane`` on macOS, both of which supply
/// those. Used to own a `NavigationStack` and a Done button when it was
/// reached from ``ScriptListView`` as a sheet; gem management is ongoing app
/// configuration, not a one-off action on a script, so it moved into
/// Settings instead.
struct GemListView: View {
    @State private var library: GemLibrary
    @State private var gemName = ""
    @State private var gemRequirement = ""

    /// The gem pending deletion confirmation, set by the context menu and by
    /// the swipe action. Non-`nil` drives the confirmation dialog on that gem's
    /// row (see `pendingDelete(of:)`).
    @State private var pendingDelete: InstalledGem?

    init(library: GemLibrary = GemLibrary()) {
        // `_library = State(initialValue:)` lets previews and tests inject a
        // VM seeded against a temp-dir store, matching `ScriptListView`.
        _library = State(initialValue: library)
    }

    var body: some View {
        content
            // Inert where the host has no navigation container (macOS's
            // `GemSettingsPane`), correct where it does (iOS/iPadOS's
            // `SettingsView`).
            .navigationTitle("Gems")
            .task {
                library.refresh()
                await library.backfillMetadata()
            }
            .task(id: gemName) {
                // Debounce: a new keystroke re-runs this task, cancelling
                // the previous one during its sleep, so only the name the
                // user has settled on ever reaches the network.
                try? await Task.sleep(for: .milliseconds(300))
                // Selecting a search result also sets `gemName`, which
                // re-triggers this task, but a plan is already resolving
                // or parked by then, so searching again would just leave a
                // stale Results section to reappear once the user cancels.
                guard library.installState == .idle else { return }
                await library.search(query: gemName)
            }
            .alert(
                "Error",
                isPresented: .init(
                    get: { library.errorMessage != nil },
                    set: { if !$0 { library.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.errorMessage ?? "")
            }
    }

    /// `pendingDelete`, narrowed to `gem`: non-`nil` only while `gem` is the
    /// one being deleted. Lets each row carry its own confirmation, so iOS
    /// 26 points the dialog at that row rather than at the top of the list
    /// (it shows confirmation dialogs as popovers on the view they're
    /// attached to).
    private func pendingDelete(of gem: InstalledGem) -> Binding<InstalledGem?> {
        .init(
            get: { pendingDelete == gem ? gem : nil },
            set: { pendingDelete = $0 }
        )
    }

    private var content: some View {
        List {
            installSection

            switch library.installState {
            case .idle:
                // The Results section only makes sense while nothing else
                // is parked or running. Once a plan lands, it stands down
                // so the two sections never compete for the same list.
                searchSection
            case .readyToInstall(let plan, let requested):
                GemPlanSection(
                    plan: plan, requested: requested,
                    onInstall: { Task { await confirmInstallTapped() } },
                    onCancel: { library.cancelPendingInstall() }
                )
            case .installing(let phase):
                GemInstallProgressSection(phase: phase)
            case .resolving:
                EmptyView()
            }

            bundledSection
            installedSection
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        switch library.searchState {
        case .idle:
            EmptyView()
        case .searching:
            Section("Results") {
                HStack {
                    ProgressView()
                    Text("Searching…")
                }
            }
        case .results(let results):
            GemSearchSection(
                results: results,
                isAvailable: { library.isAvailable($0) },
                onSelect: selectSearchResult
            )
        case .failed(let message):
            Section("Results") {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var installSection: some View {
        Section("Install a Gem") {
            TextField("Name (e.g. httparty)", text: $gemName)
                .autocorrectionDisabled()
                .disabled(library.isWorking)
            TextField("Version (optional, e.g. ~> 1.0)", text: $gemRequirement)
                .autocorrectionDisabled()
                .disabled(library.isWorking)

            if case .resolving(let gem) = library.installState {
                HStack {
                    ProgressView()
                    Text("Resolving \(gem)…")
                }
            } else {
                Button("Install") {
                    Task { await prepareInstallTapped() }
                }
                .disabled(
                    library.isWorking
                        || gemName.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
    }

    /// Gems baked into the app binary at build time (see ``BundledGem``):
    /// no delete affordance, since there's nothing on disk to remove.
    private var bundledSection: some View {
        Section("Bundled") {
            ForEach(BundledGem.all) { gem in
                VStack(alignment: .leading) {
                    Text(gem.name)
                    Text(gem.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(gem.name), version \(gem.version)")
            }
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        if library.gems.isEmpty {
            Section {
                ContentUnavailableView(
                    "No Gems Installed",
                    systemImage: "shippingbox",
                    description: Text("Install a pure-Ruby gem above to use it from a script.")
                )
            }
        } else {
            Section("Installed") {
                ForEach(library.gems) { gem in
                    let users = library.dependents(of: gem.name)
                    let usedBy =
                        users.isEmpty
                        ? "" : "used by \(ListFormatter.localizedString(byJoining: users))"
                    let usedBySuffix = usedBy.isEmpty ? "" : ", \(usedBy)"
                    VStack(alignment: .leading) {
                        Text(gem.name)
                        Text(usedBy.isEmpty ? gem.version : "\(gem.version) · \(usedBy)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(gem.name), version \(gem.version)\(usedBySuffix)")
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            pendingDelete = gem
                        }
                    }
                    // Not `.onDelete` (or a `.destructive` swipe button):
                    // both animate the row away before the confirmation
                    // appears, and cancelling never brings it back. This
                    // only asks; the row goes when the delete happens.
                    .swipeActions {
                        Button {
                            pendingDelete = gem
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                    .gemDeleteConfirmation(pendingDelete(of: gem), library: library)
                }
            }
        }
    }

    private func selectSearchResult(name: String) {
        gemName = name
        // Search reports the latest version, a requirement left over from
        // a previous attempt would silently constrain it.
        gemRequirement = ""
        library.clearSearch()
        Task { await library.prepareInstall(name: name, requirement: "") }
    }

    private func prepareInstallTapped() async {
        let name = gemName.trimmingCharacters(in: .whitespaces)
        let requirement = gemRequirement
        await library.prepareInstall(name: name, requirement: requirement)
    }

    private func confirmInstallTapped() async {
        await library.confirmInstall()
        if case .idle = library.installState, library.errorMessage == nil {
            gemName = ""
            gemRequirement = ""
        }
    }
}

/// The parked, not-yet-downloaded plan from ``GemLibrary/prepareInstall(name:requirement:)``:
/// one row per resolved gem, an "Install N Gems" primary action, and a
/// Cancel. Its own struct, not inline in ``GemListView/content``: this
/// file's sibling `ScriptListView` has a documented history of defeating the
/// type checker once conditionals and closures pile into one `body`.
/// Internal so the macOS ``GemInstallSheet`` reuses it, with
/// `showsActions: false` since that sheet has its own buttons.
struct GemPlanSection: View {
    let plan: [ResolvedGem]
    let requested: String
    let onInstall: () -> Void
    let onCancel: () -> Void
    var showsActions = true

    var body: some View {
        Section("Ready to Install") {
            ForEach(plan, id: \.name) { gem in
                row(for: gem)
            }
            if showsActions {
                Button(
                    "Install \(plan.count) \(plan.count == 1 ? "Gem" : "Gems")",
                    action: onInstall)
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
    }

    /// One plan row. `ViewThatFits` falls back to stacking the
    /// requested/dependency tag under the name and version. At large
    /// Dynamic Type sizes the horizontal layout would otherwise squeeze the
    /// tag to a truncated sliver.
    private func row(for gem: ResolvedGem) -> some View {
        ViewThatFits(in: .horizontal) {
            horizontalRow(for: gem)
            stackedRow(for: gem)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: gem))
    }

    private func horizontalRow(for gem: ResolvedGem) -> some View {
        HStack {
            nameAndVersion(for: gem)
            Spacer()
            tag(for: gem)
        }
    }

    private func stackedRow(for gem: ResolvedGem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            nameAndVersion(for: gem)
            tag(for: gem)
        }
    }

    private func nameAndVersion(for gem: ResolvedGem) -> some View {
        VStack(alignment: .leading) {
            Text(gem.name)
            Text(gem.version.raw)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func tag(for gem: ResolvedGem) -> some View {
        Text(gem.name == requested ? "requested" : "dependency")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func accessibilityLabel(for gem: ResolvedGem) -> String {
        let role = gem.name == requested ? "requested" : "dependency"
        return "\(gem.accessibilityDescription), \(role)"
    }
}

/// Live search results for the name field: one row per match, tapped to
/// resolve straight into ``GemPlanSection``. Its own struct for
/// the same type-checker reason as ``GemPlanSection``, internal so the macOS
/// ``GemInstallSheet`` reuses it. Shows "No gems
/// match" as a plain caption row rather than a `ContentUnavailableView`:
/// this is a section inside a `List`, not a whole screen.
struct GemSearchSection: View {
    let results: [GemSearchResult]
    let isAvailable: (String) -> Bool
    let onSelect: (String) -> Void

    var body: some View {
        Section("Results") {
            if results.isEmpty {
                Text("No gems match")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(results) { result in
                    Button {
                        onSelect(result.name)
                    } label: {
                        row(for: result)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(for: result))
                }
            }
        }
    }

    /// One search-result row. `ViewThatFits` falls back to stacking the
    /// installed/bundled tag under the name and info line. At large
    /// Dynamic Type sizes the horizontal layout would otherwise squeeze the
    /// tag to a truncated sliver.
    private func row(for result: GemSearchResult) -> some View {
        ViewThatFits(in: .horizontal) {
            horizontalRow(for: result)
            stackedRow(for: result)
        }
    }

    private func horizontalRow(for result: GemSearchResult) -> some View {
        HStack {
            nameAndInfo(for: result)
            Spacer()
            availabilityTag(for: result)
        }
    }

    private func stackedRow(for result: GemSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            nameAndInfo(for: result)
            availabilityTag(for: result)
        }
    }

    private func nameAndInfo(for result: GemSearchResult) -> some View {
        VStack(alignment: .leading) {
            Text(result.name)
            Text("\(result.version) — \(result.info)")
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func availabilityTag(for result: GemSearchResult) -> some View {
        if isAvailable(result.name) {
            Text(isBundled(result) ? "bundled" : "installed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func isBundled(_ result: GemSearchResult) -> Bool {
        BundledGem.all.contains { $0.name == result.name }
    }

    private func accessibilityLabel(for result: GemSearchResult) -> String {
        guard isAvailable(result.name) else { return result.accessibilityDescription }
        let tag = isBundled(result) ? "bundled" : "already installed"
        return "\(result.accessibilityDescription), \(tag)"
    }
}

/// The determinate progress shown while ``GemLibrary/confirmInstall()`` is
/// downloading and extracting a parked plan. Its own struct for
/// the same type-checker reason as ``GemPlanSection``, internal so the macOS
/// ``GemInstallSheet`` reuses it.
struct GemInstallProgressSection: View {
    let phase: GemInstallPhase

    var body: some View {
        Section {
            VStack(alignment: .leading) {
                // The label passed to `ProgressView` becomes its
                // accessibility label, otherwise VoiceOver reads only a
                // bare percentage, with the phase ("Downloading csv (1 of
                // 4)") announced as a separate, detached element below.
                // `.labelsHidden()` keeps the visual unchanged: the caption
                // `Text` underneath is still what's shown on screen.
                ProgressView(value: phase.fractionCompleted) {
                    Text(phase.label)
                }
                .labelsHidden()
                Text(phase.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    GemListPreview()
}

#Preview("Ready to Install") {
    NavigationStack {
        List {
            GemPlanSection(
                plan: [
                    ResolvedGem(
                        name: "httparty", version: GemVersion("0.22.0")!,
                        downloadURL: URL(string: "https://rubygems.org/gems/httparty-0.22.0.gem")!,
                        sha256: "sha-httparty"
                    ),
                    ResolvedGem(
                        name: "csv", version: GemVersion("3.3.0")!,
                        downloadURL: URL(string: "https://rubygems.org/gems/csv-3.3.0.gem")!,
                        sha256: "sha-csv"
                    ),
                    ResolvedGem(
                        name: "mini_mime", version: GemVersion("1.1.5")!,
                        downloadURL: URL(string: "https://rubygems.org/gems/mini_mime-1.1.5.gem")!,
                        sha256: "sha-mini_mime"
                    ),
                    ResolvedGem(
                        name: "multi_xml", version: GemVersion("0.7.1")!,
                        downloadURL: URL(string: "https://rubygems.org/gems/multi_xml-0.7.1.gem")!,
                        sha256: "sha-multi_xml"
                    ),
                ],
                requested: "httparty",
                onInstall: {},
                onCancel: {}
            )
        }
    }
    .frame(minWidth: 400, minHeight: 400)
}

#Preview("Ready to Install, Accessibility Text Size") {
    // Checks `GemPlanSection`'s `ViewThatFits` fallback: at this size the
    // requested/dependency tag no longer fits alongside the name and
    // version on one line.
    NavigationStack {
        List {
            GemPlanSection(
                plan: [
                    ResolvedGem(
                        name: "httparty", version: GemVersion("0.22.0")!,
                        downloadURL: URL(string: "https://rubygems.org/gems/httparty-0.22.0.gem")!,
                        sha256: "sha-httparty"
                    ),
                    ResolvedGem(
                        name: "csv", version: GemVersion("3.3.0")!,
                        downloadURL: URL(string: "https://rubygems.org/gems/csv-3.3.0.gem")!,
                        sha256: "sha-csv"
                    ),
                ],
                requested: "httparty",
                onInstall: {},
                onCancel: {}
            )
        }
    }
    .frame(minWidth: 400, minHeight: 400)
    .dynamicTypeSize(.accessibility3)
}

#Preview("Search Results") {
    NavigationStack {
        List {
            GemSearchSection(
                results: [
                    GemSearchResult(
                        name: "httparty", version: "0.22.0",
                        info: "Makes http fun again!", downloads: 123_456_789
                    ),
                    GemSearchResult(
                        name: "sqlite3", version: "2.9.6",
                        info: "Ruby bindings for the SQLite3 embedded database",
                        downloads: 987_654_321
                    ),
                    GemSearchResult(
                        name: "csv", version: "3.3.0",
                        info: "The CSV library provides methods for reading and writing CSV.",
                        downloads: 456_789_123
                    ),
                ],
                isAvailable: { $0 == "sqlite3" },
                onSelect: { _ in }
            )
        }
    }
    .frame(minWidth: 400, minHeight: 400)
}

#Preview("Search Results, Accessibility Text Size") {
    // Checks `GemSearchSection`'s `ViewThatFits` fallback: at this size the
    // installed/bundled tag no longer fits alongside the name and info
    // line on one line.
    NavigationStack {
        List {
            GemSearchSection(
                results: [
                    GemSearchResult(
                        name: "sqlite3", version: "2.9.6",
                        info: "Ruby bindings for the SQLite3 embedded database",
                        downloads: 987_654_321
                    )
                ],
                isAvailable: { $0 == "sqlite3" },
                onSelect: { _ in }
            )
        }
    }
    .frame(minWidth: 400, minHeight: 400)
    .dynamicTypeSize(.accessibility3)
}

#Preview("Installing") {
    NavigationStack {
        List {
            GemInstallProgressSection(
                phase: .extracting(gem: "csv", index: 1, total: 4)
            )
        }
    }
    .frame(minWidth: 400, minHeight: 200)
}

/// Backing view for ``GemListView``'s `#Preview`. Extracted into its own
/// type, mirroring ``ScriptListPreview``: side-effecting temp-dir setup
/// lives in this helper's `init` so the `#Preview` closure stays a plain
/// `ViewBuilder`. No network calls: the preview seeds ``GemStore``
/// directly with already-"installed" directories, never through
/// ``GemInstaller``.
private struct GemListPreview: View {
    @State private var library: GemLibrary

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsPreview-\(UUID().uuidString)")
        let store = GemStore(directoryURL: dir)
        _ = try? store.ensureDirectory()
        for (name, version) in [("httparty", "0.21.0"), ("csv", "3.2.8")] {
            let gemLibDir = store.destinationURL(name: name, version: version)
                .appending(component: "lib")
            try? FileManager.default.createDirectory(
                at: gemLibDir, withIntermediateDirectories: true
            )
        }
        let library = GemLibrary(store: store, installer: GemInstaller(store: store))
        library.refresh()
        _library = State(initialValue: library)
    }

    var body: some View {
        // `GemListView` no longer supplies its own navigation chrome or
        // sizing frame (see its doc comment); the preview stands in for
        // the real host so it still renders standalone.
        NavigationStack {
            GemListView(library: library)
        }
        .frame(minWidth: 400, minHeight: 400)
    }
}
