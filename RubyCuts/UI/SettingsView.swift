import SwiftUI

#if os(macOS)
    /// The macOS ⌘, Settings window's content: a "Scripts" tab (sample
    /// restore) and a "Gems" tab. Was a single ungrouped pane until this
    /// gained a second concern -- the comment that used to sit here already
    /// flagged a `TabView` as the expected next step once that happened.
    ///
    /// Wrapped in an explicit frame because a `Settings` scene has no
    /// sensible intrinsic size to fall back to -- the same class of missing
    /// desktop sizing that used to make `GemListView`'s own sheet frame
    /// necessary.
    struct GemSettingsPane: View {
        let scriptLibrary: ScriptLibrary

        var body: some View {
            TabView {
                Tab("Scripts", systemImage: "doc.text") {
                    ScriptSettingsPane(library: scriptLibrary)
                }
                Tab("Gems", systemImage: "shippingbox") {
                    GemListView()
                }
            }
            .frame(width: 480, height: 460)
        }
    }

    /// The "Scripts" tab: today just the sample-restore action. Content-only,
    /// matching ``GemListView`` -- ``GemSettingsPane`` supplies the tab
    /// chrome and sizing frame.
    private struct ScriptSettingsPane: View {
        let library: ScriptLibrary

        var body: some View {
            Form {
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
    /// `ViewBuilder`. No network calls -- seeds ``GemStore`` directly with
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
    /// The iOS/iPadOS settings sheet, presented from ``ScriptListView``'s
    /// gear button. macOS gets a `Settings` scene (``GemSettingsPane``)
    /// instead, reached from the app menu -- see `RubyCutsApp`.
    struct SettingsView: View {
        @Environment(\.dismiss) private var dismiss
        private let scriptLibrary: ScriptLibrary
        private let gemLibrary: GemLibrary

        init(scriptLibrary: ScriptLibrary, gemLibrary: GemLibrary = GemLibrary()) {
            // `GemLibrary` (not a `GemListView` instance) is what's injected
            // here, matching `GemListView`'s own init -- the `NavigationLink`
            // below constructs the destination fresh each time it's pushed.
            // `scriptLibrary` is the one shared instance from `RubyCutsApp`,
            // not a fresh default -- a restore here has to update the same
            // list `ScriptListView` shows.
            self.scriptLibrary = scriptLibrary
            self.gemLibrary = gemLibrary
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section("Sample Scripts") {
                        Button("Restore Sample Scripts") {
                            scriptLibrary.restoreSamples()
                        }
                        Text(
                            "Recreates any of the four starter samples you've deleted, by name."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    NavigationLink("Gems") {
                        GemListView(library: gemLibrary)
                    }
                }
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .alert(
                    "Error",
                    isPresented: .init(
                        get: { scriptLibrary.errorMessage != nil },
                        set: { if !$0 { scriptLibrary.errorMessage = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(scriptLibrary.errorMessage ?? "")
                }
            }
        }
    }

    #Preview {
        SettingsPreview()
    }

    /// Backing view for ``SettingsView``'s `#Preview`, mirroring
    /// ``GemListPreview``: side-effecting temp-dir setup lives in this
    /// helper's `init` so the `#Preview` closure stays a plain
    /// `ViewBuilder`. No network calls -- seeds ``GemStore`` directly with
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
