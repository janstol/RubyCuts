import SwiftUI

/// An install form (name + optional version requirement) and the list of
/// installed gems, with delete. Content-only: no navigation chrome, dismiss
/// button, or sizing frame of its own -- it's hosted by ``SettingsView`` on
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
    /// `.onDelete`. Non-`nil` drives the confirmation dialog below.
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
            .confirmationDialog(
                "Delete Gem",
                isPresented: .init(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { gem in
                Button("Delete \(gem.name)", role: .destructive) {
                    library.delete(gem)
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDelete = nil
                }
            } message: { gem in
                Text("\"\(gem.name)\" will need to be reinstalled to use it again.")
            }
    }

    private var content: some View {
        List {
            installSection

            switch library.installState {
            case .readyToInstall(let plan, let requested):
                GemPlanSection(
                    plan: plan, requested: requested,
                    onInstall: { Task { await confirmInstallTapped() } },
                    onCancel: { library.cancelPendingInstall() }
                )
            case .installing(let phase):
                GemInstallProgressSection(phase: phase)
            case .idle, .resolving:
                EmptyView()
            }

            bundledSection
            installedSection
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

    /// Gems baked into the app binary at build time (see ``BundledGem``) --
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
                    VStack(alignment: .leading) {
                        Text(gem.name)
                        Text(gem.version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            pendingDelete = gem
                        }
                    }
                }
                .onDelete { indexSet in
                    // A confirmation dialog can only present one gem at a
                    // time, so a multi-row swipe/delete only ever offers the
                    // first -- matching the context menu's single-gem
                    // confirmation rather than a batch one.
                    if let index = indexSet.first {
                        pendingDelete = library.gems[index]
                    }
                }
            }
        }
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

/// The parked, not-yet-downloaded plan from ``GemLibrary/prepareInstall(name:requirement:)``
/// -- one row per resolved gem, an "Install N Gems" primary action, and a
/// Cancel. Its own `private struct`, not inline in ``GemListView/content``:
/// this file's sibling `ScriptListView` has a documented history of defeating
/// the type checker once conditionals and closures pile into one `body`.
private struct GemPlanSection: View {
    let plan: [ResolvedGem]
    let requested: String
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Section("Ready to Install") {
            ForEach(plan, id: \.name) { gem in
                HStack {
                    VStack(alignment: .leading) {
                        Text(gem.name)
                        Text(gem.version.raw)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(gem.name == requested ? "requested" : "dependency")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Install \(plan.count) \(plan.count == 1 ? "Gem" : "Gems")", action: onInstall)
            Button("Cancel", role: .cancel, action: onCancel)
        }
    }
}

/// The determinate progress shown while ``GemLibrary/confirmInstall()`` is
/// downloading and extracting a parked plan. Its own `private struct` for
/// the same type-checker reason as ``GemPlanSection``.
private struct GemInstallProgressSection: View {
    let phase: GemInstallPhase

    var body: some View {
        Section {
            VStack(alignment: .leading) {
                ProgressView(value: phase.fractionCompleted)
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
/// `ViewBuilder`. No network calls -- the preview seeds ``GemStore``
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
        // sizing frame (see its doc comment) -- the preview stands in for
        // the real host so it still renders standalone.
        NavigationStack {
            GemListView(library: library)
        }
        .frame(minWidth: 400, minHeight: 400)
    }
}
