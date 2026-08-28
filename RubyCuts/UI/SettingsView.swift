import SwiftUI

#if os(macOS)
    /// The macOS ⌘, Settings window's content: gem management, the only
    /// pane so far. No `TabView` -- one pane doesn't need tabs, and adding a
    /// second later is a one-line change, not a restructuring.
    ///
    /// Wrapped in an explicit frame because a `Settings` scene has no
    /// sensible intrinsic size to fall back to -- the same class of missing
    /// desktop sizing that used to make `GemListView`'s own sheet frame
    /// necessary.
    struct GemSettingsPane: View {
        var body: some View {
            GemListView()
                .frame(width: 480, height: 460)
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
        @State private var library: GemLibrary

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
            _library = State(initialValue: library)
        }

        var body: some View {
            GemListView(library: library)
                .frame(width: 480, height: 460)
        }
    }
#else
    /// The iOS/iPadOS settings sheet, presented from ``ScriptListView``'s
    /// gear button. macOS gets a `Settings` scene (``GemSettingsPane``)
    /// instead, reached from the app menu -- see `RubyCutsApp`.
    struct SettingsView: View {
        @Environment(\.dismiss) private var dismiss
        private let gemLibrary: GemLibrary

        init(gemLibrary: GemLibrary = GemLibrary()) {
            // `GemLibrary` (not a `GemListView` instance) is what's injected
            // here, matching `GemListView`'s own init -- the `NavigationLink`
            // below constructs the destination fresh each time it's pushed.
            self.gemLibrary = gemLibrary
        }

        var body: some View {
            NavigationStack {
                Form {
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
        }

        var body: some View {
            SettingsView(gemLibrary: gemLibrary)
        }
    }
#endif
