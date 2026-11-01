#if os(iOS)
    import SwiftUI

    /// The iOS/iPadOS root: a tab bar with Scripts, Documentation and Settings.
    /// macOS doesn't use this; its main window is ``ScriptListView`` directly,
    /// with documentation and settings in their own windows.
    ///
    /// Tabs replaced the list's "…" menu, which hid Documentation and Settings
    /// behind an extra tap. The tab bar also takes them out of the Scripts
    /// toolbar, which only has room for two items beside the title in the
    /// regular-width sidebar.
    struct RootTabView: View {
        /// The tabs, in tab-bar order.
        enum AppTab: Hashable {
            case scripts
            case documentation
            case settings
        }

        let library: ScriptLibrary

        @State private var selectedTab: AppTab = .scripts

        var body: some View {
            TabView(selection: $selectedTab) {
                Tab("Scripts", systemImage: "doc.text", value: AppTab.scripts) {
                    ScriptListView(library: library) {
                        selectedTab = .documentation
                    }
                }
                Tab("Documentation", systemImage: "book", value: AppTab.documentation) {
                    NavigationStack {
                        DocumentationView()
                    }
                }
                Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                    SettingsView(scriptLibrary: library)
                }
            }
            // One alert for the library's errors, here rather than in each
            // tab: the Scripts and Settings tabs both stay alive, and two
            // alerts bound to the same state would compete to present it.
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
        RootTabPreview()
    }

    /// Backing view for ``RootTabView``'s `#Preview`: seeds a temp-dir store
    /// in `init`, so the preview closure stays a plain `ViewBuilder`.
    private struct RootTabPreview: View {
        @State private var library: ScriptLibrary

        init() {
            let dir = FileManager.default.temporaryDirectory
                .appending(component: "RubyCutsPreview-\(UUID().uuidString)")
            let store = ScriptStore(directoryURL: dir)
            _ = try? store.ensureDirectory()
            _ = try? store.create(name: "hello", source: "puts 'hi'")
            let library = ScriptLibrary(store: store)
            library.refresh()
            _library = State(initialValue: library)
        }

        var body: some View {
            RootTabView(library: library)
        }
    }
#endif
