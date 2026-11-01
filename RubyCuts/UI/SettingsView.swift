import SwiftUI

/// The "Storage" section shared by the macOS Scripts pane and the iOS
/// settings form: where scripts live right now, and in local mode, how to get
/// them syncing.
private struct ScriptStorageSection: View {
    let location: ScriptStorageLocation

    var body: some View {
        Section {
            switch location {
            case .iCloud:
                LabeledContent {
                    Text("iCloud Drive")
                } label: {
                    Label("Scripts", systemImage: "icloud")
                }
            case .local:
                LabeledContent {
                    Text("On This Device")
                } label: {
                    Label("Scripts", systemImage: "iphone")
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            if location == .local {
                Text(
                    "To sync scripts across your devices, sign in to iCloud and turn on iCloud Drive for RubyCuts."
                )
            }
        }
    }
}

#if os(macOS)
    /// The macOS ⌘, Settings window's content: a "Scripts" tab (sample
    /// restore) and a "Gems" tab. Was a single ungrouped pane until this
    /// gained a second concern. The comment that used to sit here already
    /// flagged a `TabView` as the expected next step once that happened.
    ///
    /// Each tab gets its own frame, because a `Settings` scene has no
    /// sensible intrinsic size to fall back to, and so the window takes
    /// each tab's height instead of one size for both. `min`/`ideal` rather
    /// than a hard `width`/`height`: at macOS's larger-text accessibility
    /// setting a fixed frame clips its content instead of growing to fit it.
    ///
    /// The Gems tab is ``GemSettingsMacPane``, not the iOS ``GemListView``,
    /// whose one long `List` looked out of place in a Mac settings window.
    struct GemSettingsPane: View {
        let scriptLibrary: ScriptLibrary

        var body: some View {
            TabView {
                Tab("Scripts", systemImage: "doc.text") {
                    ScriptSettingsPane(library: scriptLibrary)
                        .frame(minWidth: 500, idealWidth: 500, minHeight: 300, idealHeight: 300)
                }
                #if RUBYCUTS_GEMS
                    Tab("Gems", systemImage: "shippingbox") {
                        GemSettingsMacPane()
                            .frame(minWidth: 500, idealWidth: 500, minHeight: 420, idealHeight: 420)
                    }
                #endif
            }
        }
    }

    /// The "Scripts" tab: today just the sample-restore action. Content-only,
    /// matching ``GemListView``: ``GemSettingsPane`` supplies the tab
    /// chrome and sizing frame.
    private struct ScriptSettingsPane: View {
        let library: ScriptLibrary

        var body: some View {
            Form {
                ScriptStorageSection(location: library.storageLocation)
                Section("Sample Scripts") {
                    Button("Restore Sample Scripts") {
                        library.restoreSamples()
                    }
                    Text("Recreates any of the four starter samples you've deleted, by name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
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
    }

    #Preview {
        GemSettingsPreview()
    }

    /// Backing view for ``GemSettingsPane``'s `#Preview`, mirroring
    /// ``GemListPreview``: side-effecting temp-dir setup lives in this
    /// helper's `init` so the `#Preview` closure stays a plain
    /// `ViewBuilder`. No network calls: seeds ``GemStore`` directly with
    /// already-"installed" directories, never through ``GemInstaller``.
    private struct GemSettingsPreview: View {
        @State private var gemLibrary: GemLibrary
        @State private var scriptLibrary: ScriptLibrary

        init() {
            let dir = FileManager.default.temporaryDirectory
                .appending(component: "RubyCutsPreview-\(UUID().uuidString)")
            let store = GemStore(directoryURL: dir)
            _ = try? store.ensureDirectory()
            let gemLibDir = store.destinationURL(name: "httparty", version: "0.21.0")
                .appending(component: "lib")
            try? FileManager.default.createDirectory(
                at: gemLibDir, withIntermediateDirectories: true
            )
            let library = GemLibrary(store: store, installer: GemInstaller(store: store))
            library.refresh()
            _gemLibrary = State(initialValue: library)

            let scriptDir = FileManager.default.temporaryDirectory
                .appending(component: "RubyCutsPreview-\(UUID().uuidString)")
            let scriptStore = ScriptStore(directoryURL: scriptDir)
            _ = try? scriptStore.ensureDirectory()
            let previewDefaults = UserDefaults(suiteName: "RubyCutsPreview-\(UUID().uuidString)")!
            _scriptLibrary = State(
                initialValue: ScriptLibrary(store: scriptStore, defaults: previewDefaults))
        }

        var body: some View {
            GemSettingsPane(scriptLibrary: scriptLibrary)
        }
    }
#else
    /// The iOS/iPadOS Settings tab of ``RootTabView``. macOS gets a `Settings` scene (``GemSettingsPane``)
    /// instead, reached from the app menu; see `RubyCutsApp`.
    struct SettingsView: View {
        private let scriptLibrary: ScriptLibrary
        private let gemLibrary: GemLibrary

        init(scriptLibrary: ScriptLibrary, gemLibrary: GemLibrary = GemLibrary()) {
            // `GemLibrary` (not a `GemListView` instance) is what's injected
            // here, matching `GemListView`'s own init. The `NavigationLink`
            // below constructs the destination fresh each time it's pushed.
            // `scriptLibrary` is the one shared instance from `RubyCutsApp`,
            // not a fresh default: a restore here has to update the same
            // list `ScriptListView` shows.
            self.scriptLibrary = scriptLibrary
            self.gemLibrary = gemLibrary
        }

        var body: some View {
            NavigationStack {
                Form {
                    ScriptStorageSection(location: scriptLibrary.storageLocation)
                    Section {
                        Button {
                            scriptLibrary.restoreSamples()
                        } label: {
                            Label("Restore Sample Scripts", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(allSamplesPresent)
                    } header: {
                        Text("Sample Scripts")
                    } footer: {
                        Text(
                            allSamplesPresent
                                ? "All starter samples are in your library."
                                : "Recreates any of the starter samples you've deleted, by name."
                        )
                    }
                    #if RUBYCUTS_GEMS
                        Section {
                            NavigationLink {
                                GemListView(library: gemLibrary)
                            } label: {
                                Label("Gems", systemImage: "shippingbox")
                            }
                        } footer: {
                            Text("Install gems from rubygems.org for your scripts to require.")
                        }
                    #endif
                    AboutSection(info: AppInfo.current)
                }
                .navigationTitle("Settings")
                // Errors from restoring samples are shown by
                // ``RootTabView``'s alert, which covers every tab.
            }
        }

        /// Whether every starter sample already exists by name, in which case
        /// restoring would be a no-op, so the button is disabled instead of
        /// silently doing nothing.
        private var allSamplesPresent: Bool {
            let names = Set(scriptLibrary.scripts.map(\.name))
            return SampleScripts.all.allSatisfy { names.contains($0.name) }
        }
    }

    /// The last section of the settings sheet: version info, project links,
    /// and the open-source acknowledgements. macOS doesn't need this, since
    /// it synthesises an About panel from the same `Info.plist` keys and
    /// carries the links in the Help menu (see ``ScriptCommands``).
    private struct AboutSection: View {
        let info: AppInfo

        var body: some View {
            Section {
                LabeledContent("Version", value: info.versionAndBuild)
                LabeledContent("Ruby", value: info.rubyVersion)
                Link(destination: AppInfo.sourceCodeURL) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: AppInfo.privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                NavigationLink {
                    AcknowledgementsView()
                } label: {
                    Label("Acknowledgements", systemImage: "doc.text")
                }
            } header: {
                Text("About")
            } footer: {
                Text("RubyCuts is open source under the MIT License.")
            }
        }
    }

    #Preview {
        SettingsPreview()
    }

    /// Backing view for ``SettingsView``'s `#Preview`, mirroring
    /// ``GemListPreview``: side-effecting temp-dir setup lives in this
    /// helper's `init` so the `#Preview` closure stays a plain
    /// `ViewBuilder`. No network calls: seeds ``GemStore`` directly with
    /// an already-"installed" directory, never through ``GemInstaller``.
    private struct SettingsPreview: View {
        @State private var gemLibrary: GemLibrary
        @State private var scriptLibrary: ScriptLibrary

        init() {
            let dir = FileManager.default.temporaryDirectory
                .appending(component: "RubyCutsPreview-\(UUID().uuidString)")
            let store = GemStore(directoryURL: dir)
            _ = try? store.ensureDirectory()
            let gemLibDir = store.destinationURL(name: "httparty", version: "0.21.0")
                .appending(component: "lib")
            try? FileManager.default.createDirectory(
                at: gemLibDir, withIntermediateDirectories: true
            )
            _gemLibrary = State(
                initialValue: GemLibrary(store: store, installer: GemInstaller(store: store)))

            let scriptDir = FileManager.default.temporaryDirectory
                .appending(component: "RubyCutsPreview-\(UUID().uuidString)")
            let scriptStore = ScriptStore(directoryURL: scriptDir)
            _ = try? scriptStore.ensureDirectory()
            let previewDefaults = UserDefaults(suiteName: "RubyCutsPreview-\(UUID().uuidString)")!
            _scriptLibrary = State(
                initialValue: ScriptLibrary(store: scriptStore, defaults: previewDefaults))
        }

        var body: some View {
            SettingsView(scriptLibrary: scriptLibrary, gemLibrary: gemLibrary)
        }
    }
#endif
