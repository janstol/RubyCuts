import SwiftUI

#if os(macOS)
    /// The macOS Settings "Gems" tab: every gem the VM can load (bundled and
    /// installed) in one bordered table, with + and − buttons under it in the
    /// style of Xcode's Accounts or Mail's account list. + opens
    /// ``GemInstallSheet``; − (or Delete in the context menu) removes an
    /// installed gem after confirmation. Bundled gems can't be removed.
    ///
    /// macOS only. iOS/iPadOS keep ``GemListView``, whose single `List` with
    /// an install form at the top reads naturally there but looked out of
    /// place in a Mac settings window.
    struct GemSettingsMacPane: View {
        @State private var library: GemLibrary
        @State private var selection: GemTableRow.ID?
        @State private var isPresentingInstall = false

        /// The gem pending deletion confirmation. Non-`nil` drives the dialog.
        @State private var pendingDelete: InstalledGem?

        init(library: GemLibrary = GemLibrary()) {
            _library = State(initialValue: library)
        }

        /// Bundled gems first (as the iOS list orders them), then installed
        /// ones in the store's order.
        private var rows: [GemTableRow] {
            BundledGem.all.map { GemTableRow(name: $0.name, version: $0.version, installed: nil) }
                + library.gems.map {
                    GemTableRow(name: $0.name, version: $0.version, installed: $0)
                }
        }

        /// The installed gem the selection points at, if any. `nil` for a
        /// bundled row, which is what disables −.
        private var selectedInstalledGem: InstalledGem? {
            rows.first { $0.id == selection }?.installed
        }

        var body: some View {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 0) {
                        table
                        controlBar
                    }
                } footer: {
                    Text(
                        "Pure-Ruby gems only. Installed gems stay on this Mac and don't sync through iCloud."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .task {
                library.refresh()
                await library.backfillMetadata()
            }
            .sheet(isPresented: $isPresentingInstall) {
                GemInstallSheet(library: library)
            }
            .alert(
                "Error",
                isPresented: .init(
                    // The sheet shows its own alert for install errors.
                    get: { library.errorMessage != nil && !isPresentingInstall },
                    set: { if !$0 { library.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.errorMessage ?? "")
            }
            .gemDeleteConfirmation($pendingDelete, library: library) {
                selection = nil
            }
        }

        /// The third column: "Bundled", "Used by httparty", or nothing for a
        /// gem no other installed gem needs.
        private func note(for row: GemTableRow) -> String {
            guard row.installed != nil else { return "Bundled" }
            let users = library.dependents(of: row.name)
            return users.isEmpty ? "" : "Used by \(ListFormatter.localizedString(byJoining: users))"
        }

        private var table: some View {
            Table(rows, selection: $selection) {
                TableColumn("Name", value: \.name)
                TableColumn("Version", value: \.version)
                    .width(min: 60, ideal: 80)
                TableColumn("") { row in
                    Text(note(for: row))
                        .foregroundStyle(.secondary)
                        .help(note(for: row))
                }
                .width(min: 60, ideal: 160)
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 180)
            .contextMenu(forSelectionType: GemTableRow.ID.self) { ids in
                if let gem = rows.first(where: { ids.contains($0.id) })?.installed {
                    Button("Delete \(gem.name)…", role: .destructive) {
                        pendingDelete = gem
                    }
                }
            }
        }

        /// The + / − strip glued under the table, the standard macOS
        /// add/remove affordance.
        private var controlBar: some View {
            HStack(spacing: 0) {
                Button {
                    isPresentingInstall = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 20)
                }
                .help("Install a gem")
                .accessibilityLabel("Install Gem")

                Divider().frame(height: 16)

                Button {
                    pendingDelete = selectedInstalledGem
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .disabled(selectedInstalledGem == nil)
                .help("Delete the selected gem")
                .accessibilityLabel("Delete Gem")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
    }

    /// One row of ``GemSettingsMacPane``'s table. `installed` is `nil` for a
    /// bundled gem, which has nothing on disk to delete.
    struct GemTableRow: Identifiable {
        let name: String
        let version: String
        let installed: InstalledGem?

        /// A gem name is unique across both lists: ``GemInstaller`` refuses
        /// to install a bundled gem or a second version of an installed one.
        var id: String { name }
    }

    /// The sheet behind ``GemSettingsMacPane``'s + button: name and optional
    /// version, live rubygems.org search results while typing, then the
    /// resolved plan and install progress. The same ``GemLibrary`` flow as
    /// ``GemListView``'s install section, laid out as a Mac sheet with the
    /// actions at the bottom right. Closes itself after a successful
    /// install.
    struct GemInstallSheet: View {
        let library: GemLibrary
        @Environment(\.dismiss) private var dismiss
        @State private var gemName = ""
        @State private var gemRequirement = ""

        var body: some View {
            VStack(spacing: 0) {
                Form {
                    Section("Install a Gem") {
                        TextField("Name", text: $gemName, prompt: Text("e.g. httparty"))
                            .autocorrectionDisabled()
                            .disabled(library.isWorking || isPlanParked)
                            .onSubmit { Task { await findTapped() } }
                        TextField(
                            "Version", text: $gemRequirement, prompt: Text("Optional, e.g. ~> 1.0")
                        )
                        .autocorrectionDisabled()
                        .disabled(library.isWorking || isPlanParked)
                        .onSubmit { Task { await findTapped() } }
                    }
                    stateSection
                }
                .formStyle(.grouped)

                Divider()
                buttons
                    .padding()
            }
            .frame(width: 460, height: 440)
            .interactiveDismissDisabled(library.isWorking)
            .task(id: gemName) {
                // Debounced like ``GemListView``: a new keystroke cancels the
                // previous wait, so only a settled name reaches the network.
                try? await Task.sleep(for: .milliseconds(300))
                guard library.installState == .idle else { return }
                await library.search(query: gemName)
            }
            .onDisappear {
                if isPlanParked {
                    library.cancelPendingInstall()
                }
                library.clearSearch()
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

        private var isPlanParked: Bool {
            if case .readyToInstall = library.installState { return true }
            return false
        }

        @ViewBuilder
        private var stateSection: some View {
            switch library.installState {
            case .idle:
                searchSection
            case .resolving(let gem):
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Resolving \(gem)…")
                    }
                }
            case .readyToInstall(let plan, let requested):
                GemPlanSection(
                    plan: plan, requested: requested,
                    onInstall: { Task { await installTapped() } },
                    onCancel: { library.cancelPendingInstall() },
                    showsActions: false
                )
            case .installing(let phase):
                GemInstallProgressSection(phase: phase)
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
                        ProgressView().controlSize(.small)
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

        /// Cancel on the left of the primary action, as macOS sheets do.
        /// The primary action follows the flow: Find resolves the typed
        /// name, Install confirms the parked plan.
        private var buttons: some View {
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(library.isWorking)

                if case .readyToInstall(let plan, _) = library.installState {
                    Button("Install \(plan.count) \(plan.count == 1 ? "Gem" : "Gems")") {
                        Task { await installTapped() }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Find") {
                        Task { await findTapped() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        library.isWorking
                            || gemName.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }
            }
        }

        private func selectSearchResult(name: String) {
            gemName = name
            // Search reports the latest version; a requirement left over
            // from a previous attempt would silently constrain it.
            gemRequirement = ""
            library.clearSearch()
            Task { await library.prepareInstall(name: name, requirement: "") }
        }

        private func findTapped() async {
            guard !library.isWorking, !isPlanParked else { return }
            let name = gemName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            library.clearSearch()
            await library.prepareInstall(name: name, requirement: gemRequirement)
        }

        private func installTapped() async {
            await library.confirmInstall()
            if case .idle = library.installState, library.errorMessage == nil {
                dismiss()
            }
        }
    }

    #Preview("Gems Pane") {
        GemSettingsMacPanePreview()
    }

    #Preview("Install Sheet") {
        GemInstallSheet(library: GemSettingsMacPanePreview.makeLibrary())
    }

    /// Backing view for the previews, mirroring ``GemListPreview``: the
    /// temp-dir setup lives in a helper so the `#Preview` closures stay
    /// plain `ViewBuilder`s. No network calls: gems are "installed" by
    /// creating their directories directly, never through ``GemInstaller``.
    private struct GemSettingsMacPanePreview: View {
        @State private var library = Self.makeLibrary()

        var body: some View {
            GemSettingsMacPane(library: library)
                .frame(width: 500, height: 420)
        }

        static func makeLibrary() -> GemLibrary {
            let dir = FileManager.default.temporaryDirectory
                .appending(component: "RubyCutsPreview-\(UUID().uuidString)")
            let store = GemStore(directoryURL: dir)
            _ = try? store.ensureDirectory()
            for (name, version) in [("csv", "3.3.6"), ("httparty", "0.24.2")] {
                let lib = store.destinationURL(name: name, version: version).appending(
                    component: "lib")
                try? FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
            }
            let library = GemLibrary(store: store, installer: GemInstaller(store: store))
            library.refresh()
            return library
        }
    }
#endif
