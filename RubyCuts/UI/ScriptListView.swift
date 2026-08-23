import SwiftUI

/// The app's root view: a list of scripts backed by ``ScriptLibrary``, with
/// create / open / delete. Replaces the Phase 1 placeholder `ContentView`.
///
/// This is the first real product surface and
/// establishes the pattern future views follow: an `@Observable` view model
/// (`ScriptLibrary`), injected store, error handling via an alert bound to the
/// VM's `errorMessage`, and a `#Preview` on a temp-dir store with mock data.
struct ScriptListView: View {
    @State private var library: ScriptLibrary
    @State private var path = NavigationPath()

    /// Name being typed into the "new script" alert, and whether the alert is
    /// showing. Kept here on the view (not the VM) because it's UI state, not
    /// list state.
    @State private var newName = "Untitled"
    @State private var isPresentingNewAlert = false

    init(library: ScriptLibrary = ScriptLibrary()) {
        // `_library = State(initialValue:)` lets previews and tests inject a
        // VM seeded against a temp-dir store; the default still works for the
        // real app, which uses `.userScripts`.
        _library = State(initialValue: library)
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Scripts")
                .navigationDestination(for: Script.self) { script in
                    ScriptEditorView(script: script, store: library.storeForEditing)
                }
        }
        .task {
            library.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newName = "Untitled"
                    isPresentingNewAlert = true
                } label: {
                    Label("New Script", systemImage: "plus")
                }
            }
        }
        .alert("New Script", isPresented: $isPresentingNewAlert) {
            TextField("Name", text: $newName)
            Button("Create") {
                createNew()
            }
            Button("Cancel", role: .cancel) {}
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

    @ViewBuilder
    private var content: some View {
        if library.scripts.isEmpty {
            ContentUnavailableView(
                "No Scripts Yet",
                systemImage: "doc.text",
                description: Text("Tap + to create a Ruby script.")
            )
        } else {
            List {
                ForEach(library.scripts) { script in
                    NavigationLink(value: script) {
                        Text(script.name)
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            library.delete(script)
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        library.delete(library.scripts[index])
                    }
                }
            }
        }
    }

    private func createNew() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Defaulting the field to "Untitled" means an empty submit still creates
        // something usable; the store also rejects empty/whitespace-only names.
        let resolved = name.isEmpty ? "Untitled" : name
        if let script = library.create(name: resolved) {
            path.append(script)
        }
    }
}

#Preview {
    ScriptListPreview()
}

/// Backing view for ``ScriptListView``'s `#Preview`. Extracted into its own
/// type so the preview body stays a plain `ViewBuilder` -- seeding a temp-dir
/// store with mock scripts and refreshing the VM is local file I/O (allowed in
/// previews per the repo convention), but mixing those side-effecting calls
/// into the preview closure overloads the typechecker.
private struct ScriptListPreview: View {
    @State private var library: ScriptLibrary

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsPreview-\(UUID().uuidString)")
        let store = ScriptStore(directoryURL: dir)
        _ = try? store.ensureDirectory()
        _ = try? store.create(name: "hello", source: "puts 'hi'")
        _ = try? store.create(name: "fib", source: "puts fib(10)")
        let library = ScriptLibrary(store: store)
        library.refresh()
        _library = State(initialValue: library)
    }

    var body: some View {
        ScriptListView(library: library)
            .frame(minWidth: 400, minHeight: 300)
    }
}
