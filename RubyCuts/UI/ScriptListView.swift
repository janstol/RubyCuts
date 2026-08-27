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
    @State private var selection: Script?

    /// Name being typed into the "new script" alert, and whether the alert is
    /// showing. Kept here on the view (not the VM) because it's UI state, not
    /// list state.
    @State private var newName = "Untitled"
    @State private var isPresentingNewAlert = false
    @State private var isPresentingGems = false

    /// The script being renamed, and the name typed into the rename alert.
    /// Mirrors ``newName``/``isPresentingNewAlert`` above: `renameTarget`
    /// non-`nil` drives the alert's presentation, so there's no separate
    /// `isPresenting` flag to keep in sync with it.
    @State private var renameTarget: Script?
    @State private var renameName = ""

    /// The script pending deletion confirmation, set by the context menu and
    /// by `.onDelete`. Non-`nil` drives the confirmation dialog below.
    @State private var pendingDelete: Script?

    init(library: ScriptLibrary = ScriptLibrary()) {
        // `_library = State(initialValue:)` lets previews and tests inject a
        // VM seeded against a temp-dir store; the default still works for the
        // real app, which uses `.userScripts`.
        _library = State(initialValue: library)
    }

    var body: some View {
        NavigationSplitView {
            content
                .navigationTitle("Scripts")
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
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
                    ToolbarItem(placement: .automatic) {
                        Button {
                            isPresentingGems = true
                        } label: {
                            Label("Gems", systemImage: "shippingbox")
                        }
                    }
                }
                .sheet(isPresented: $isPresentingGems) {
                    GemListView()
                }
                .alert("New Script", isPresented: $isPresentingNewAlert) {
                    TextField("Name", text: $newName)
                    Button("Create") {
                        createNew()
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .alert(
                    "Rename Script",
                    isPresented: .init(
                        get: { renameTarget != nil },
                        set: { if !$0 { renameTarget = nil } }
                    )
                ) {
                    TextField("Name", text: $renameName)
                    Button("Rename") {
                        renameCurrentTarget()
                    }
                    Button("Cancel", role: .cancel) {
                        renameTarget = nil
                    }
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
                    "Delete Script",
                    isPresented: .init(
                        get: { pendingDelete != nil },
                        set: { if !$0 { pendingDelete = nil } }
                    ),
                    presenting: pendingDelete
                ) { script in
                    Button("Delete \(script.name)", role: .destructive) {
                        library.delete(script)
                        if selection == script {
                            selection = nil
                        }
                        pendingDelete = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingDelete = nil
                    }
                } message: { script in
                    Text("\"\(script.name)\" can't be recovered once deleted.")
                }
        } detail: {
            if let selection {
                ScriptEditorView(script: selection, store: library.storeForEditing) {
                    message in
                    library.errorMessage = message
                }
                .id(selection)
            } else {
                ContentUnavailableView(
                    "No Script Selected", systemImage: "doc.text")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.scripts.isEmpty {
            ContentUnavailableView {
                Label("No Scripts Yet", systemImage: "doc.text")
            } description: {
                Text("Create a Ruby script to run it from the app or from a Shortcut.")
            } actions: {
                Button("New Script") {
                    newName = "Untitled"
                    isPresentingNewAlert = true
                }
            }
        } else {
            List(selection: $selection) {
                ForEach(library.scripts) { script in
                    Text(script.name)
                        .tag(script)
                        .contextMenu {
                            Button("Rename") {
                                renameTarget = script
                                renameName = script.name
                            }
                            Button("Delete", role: .destructive) {
                                pendingDelete = script
                            }
                        }
                }
                .onDelete { indexSet in
                    // A confirmation dialog can only present one script at a
                    // time, so a multi-row swipe/delete only ever offers the
                    // first -- matching the context menu's single-script
                    // confirmation rather than a batch one.
                    if let index = indexSet.first {
                        pendingDelete = library.scripts[index]
                    }
                }
            }
        }
    }

    private func renameCurrentTarget() {
        guard let script = renameTarget else { return }
        renameTarget = nil
        guard let renamed = library.rename(script, to: renameName) else { return }
        if selection == script {
            selection = renamed
        }
    }

    private func createNew() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Defaulting the field to "Untitled" means an empty submit still creates
        // something usable; the store also rejects empty/whitespace-only names.
        let resolved = name.isEmpty ? "Untitled" : name
        if let script = library.create(name: resolved) {
            selection = script
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
