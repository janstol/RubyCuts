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
    @State private var isPresentingSettings = false

    /// Drives the iOS/iPadOS reference sheet, reached from the toolbar's info
    /// button and the empty state's "What is RubyCuts?" action. macOS opens
    /// the dedicated ``RubyCutsApp`` reference window instead (see
    /// `openReference()`), so this only matters off macOS.
    @State private var isPresentingReference = false

    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    /// The script being renamed, driving a ``RenameSheet``. Non-`nil` drives
    /// the sheet's presentation, so there's no separate `isPresenting` flag
    /// to keep in sync with it. Rename used to be an `.alert` with a
    /// `TextField`, but on macOS that field reliably opened empty across
    /// repeated presentations regardless of how the backing state was
    /// plumbed -- a known SwiftUI/AppKit issue with `.alert`'s text field,
    /// not an app bug. A sheet with its own local state sidesteps it.
    @State private var renameTarget: Script?

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
                    library.seedSamplesIfNeeded()
                    library.refresh()
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            presentNewScriptAlert()
                        } label: {
                            Label("New Script", systemImage: "plus")
                        }
                    }
                    #if !os(macOS)
                        // macOS reaches these through the app menu (⌘, and
                        // ⌘?); this gear and info button are their
                        // iOS/iPadOS equivalents.
                        ToolbarItem(placement: .automatic) {
                            Button {
                                isPresentingReference = true
                            } label: {
                                Label("Reference", systemImage: "info.circle")
                            }
                        }
                        ToolbarItem(placement: .automatic) {
                            Button {
                                isPresentingSettings = true
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                        }
                    #endif
                }
                #if !os(macOS)
                    .sheet(isPresented: $isPresentingSettings) {
                        SettingsView(scriptLibrary: library)
                    }
                    .sheet(isPresented: $isPresentingReference) {
                        NavigationStack {
                            ReferenceView()
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { isPresentingReference = false }
                                }
                            }
                        }
                    }
                #endif
                .focusedSceneValue(\.newScriptAction, presentNewScriptAlert)
                .alert("New Script", isPresented: $isPresentingNewAlert) {
                    TextField("Name", text: $newName)
                    Button("Create") {
                        createNew()
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .sheet(
                    isPresented: .init(
                        get: { renameTarget != nil },
                        set: { if !$0 { renameTarget = nil } }
                    )
                ) {
                    if let target = renameTarget {
                        RenameSheet(scriptName: target.name) { newName in
                            renameTarget = nil
                            guard let renamed = library.rename(target, to: newName) else {
                                return
                            }
                            if selection == target {
                                selection = renamed
                            }
                        } onCancel: {
                            renameTarget = nil
                        }
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
            if let script = selection {
                ScriptEditorView(
                    script: script,
                    store: library.storeForEditing,
                    onSaveError: { library.errorMessage = $0 },
                    onRename: { newName in
                        guard let renamed = library.rename(script, to: newName) else {
                            return nil
                        }
                        selection = renamed
                        return renamed
                    }
                )
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
                    presentNewScriptAlert()
                }
                Button("What is RubyCuts?") {
                    openReference()
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

    /// Resets the new-script name field and shows the naming alert. Shared
    /// by the toolbar button, the empty-state action, and the macOS ⌘N menu
    /// command (via `.focusedSceneValue(\.newScriptAction, ...)` above), so
    /// all three stay in sync with a single implementation.
    private func presentNewScriptAlert() {
        newName = "Untitled"
        isPresentingNewAlert = true
    }

    /// Opens the reference: the dedicated `Window` scene on macOS (see
    /// `RubyCutsApp`), a sheet everywhere else. Shared by the toolbar's info
    /// button and the empty state's "What is RubyCuts?" action.
    private func openReference() {
        #if os(macOS)
            openWindow(id: "reference")
        #else
            isPresentingReference = true
        #endif
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

/// A single-field rename dialog, reached from the list row's context menu.
/// Deliberately a sheet with its own local `@State` rather than an `.alert`
/// with a `TextField` -- the alert version reliably opened with an empty
/// field on macOS across repeated presentations, confirmed live testing,
/// regardless of how the backing state was plumbed. That's a known
/// SwiftUI/AppKit issue with `.alert`'s text field, not something app-level
/// state management can work around; a sheet's content is a fresh view with
/// its own state each time it's presented, which sidesteps it entirely.
private struct RenameSheet: View {
    let scriptName: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @FocusState private var isNameFocused: Bool

    init(scriptName: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.scriptName = scriptName
        self.onCommit = onCommit
        self.onCancel = onCancel
        self._name = State(initialValue: scriptName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            // A plain padded field, not a `Form` -- a `Form` here rendered
            // the field flush against the sheet's edges with a stray
            // full-width divider and no room to breathe, since a
            // single-row Form doesn't get the grouped-section insets that
            // make a `Form` look right. This is simple enough not to need
            // `Form`'s section machinery anyway.
            TextField("Name", text: $name)
                .focused($isNameFocused)
                .onSubmit {
                    if !trimmedName.isEmpty {
                        onCommit(trimmedName)
                    }
                }
                .padding()
                .navigationTitle("Rename Script")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel, action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Rename") {
                            onCommit(trimmedName)
                        }
                        .disabled(trimmedName.isEmpty)
                    }
                }
        }
        .onAppear {
            isNameFocused = true
        }
        // Same macOS sheet-sizing issue as `GemListView` -- without an
        // explicit frame the sheet can collapse to fit almost nothing. No
        // `minHeight` here (unlike `GemListView`'s list-based one): a fixed
        // one left dead space below this single field, since the toolbar's
        // button bar pins to the window bottom regardless of content height.
        .frame(minWidth: 320)
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
