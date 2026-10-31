import SwiftUI

/// The app's root view: a list of scripts backed by ``ScriptLibrary``, with
/// create / open / delete. Replaces the original placeholder `ContentView`.
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

    /// The sidebar's search field text. Transient per-appearance UI state,
    /// same reasoning as `newName` above: ``ScriptLibrary/sortOrder`` is
    /// list *configuration* and persists, but a search filter is not
    /// something a relaunch should remember.
    @State private var searchText = ""

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
    /// plumbed, a known SwiftUI/AppKit issue with `.alert`'s text field,
    /// not an app bug. A sheet with its own local state sidesteps it.
    @State private var renameTarget: Script?

    /// The script pending deletion confirmation, set by the context menu and
    /// by the swipe action and, on macOS, the Delete key. Non-`nil` drives
    /// the confirmation dialog on that script's row (see `row(for:)`).
    @State private var pendingDelete: Script?

    init(library: ScriptLibrary = ScriptLibrary()) {
        // `_library = State(initialValue:)` lets previews and tests inject a
        // VM seeded against a temp-dir store; the default still works for the
        // real app, whose library resolves local or iCloud storage in
        // `prepareStorage()`.
        _library = State(initialValue: library)
    }

    var body: some View {
        NavigationSplitView {
            content
                .navigationTitle("Scripts")
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
                .searchable(text: $searchText, prompt: "Search Scripts")
                .task {
                    await library.prepareStorage()
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            presentNewScriptAlert()
                        } label: {
                            Label("New Script", systemImage: "plus")
                        }
                    }
                    #if os(macOS)
                        sortMenuToolbarItem
                    #else
                        moreMenuToolbarItem
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
                .focusedSceneValue(\.newScriptAction, newScriptCommand)
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
        } detail: {
            if let script = selection {
                ScriptEditorView(
                    script: script,
                    store: library.storeForEditing,
                    onSaveError: { library.errorMessage = $0 },
                    onSaved: { library.refresh() },
                    onRename: { newName in
                        guard let renamed = library.rename(script, to: newName) else {
                            return nil
                        }
                        selection = renamed
                        return renamed
                    },
                    onFlushHookChange: { hook in
                        if let hook {
                            library.registerEditorSave(for: script, hook)
                        } else {
                            library.unregisterEditorSave(for: script)
                        }
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
        } else if filteredScripts.isEmpty {
            // Distinct from the "No Scripts Yet" empty state above: the
            // library has scripts, the search text just doesn't match any
            // of their names.
            ContentUnavailableView.search(text: searchText)
        } else {
            List(selection: $selection) {
                ForEach(filteredScripts) { script in
                    row(for: script)
                }
            }
            #if os(macOS)
                // The Delete key and Edit ▸ Delete, which `.onDelete` used to
                // provide on macOS. Also only asks.
                .onDeleteCommand {
                    pendingDelete = selection
                }
            #endif
        }
    }

    /// One sidebar row with its rename/delete affordances. Split out of
    /// `content` to keep that expression small for the type checker.
    private func row(for script: Script) -> some View {
        ScriptRow(script: script)
            .tag(script)
            .contextMenu {
                Button("Rename") {
                    renameTarget = script
                }
                Button("Delete", role: .destructive) {
                    pendingDelete = script
                }
            }
            // A swipe action, not `.onDelete`: `.onDelete` animates the row
            // away before the confirmation appears, and cancelling never
            // brings it back. This only asks; the row goes when the delete
            // happens. Not `role: .destructive` either, which removes the row
            // the same way; tinted red to look the part.
            .swipeActions {
                Button {
                    pendingDelete = script
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
            // On the row, not the list: iOS 26 shows a confirmation dialog as
            // a popover pointing at the view it's attached to, so attached to
            // the whole list it always appeared at the top of the screen.
            .confirmationDialog(
                "Delete Script",
                isPresented: .init(
                    get: { pendingDelete == script },
                    set: { if !$0 { pendingDelete = nil } }
                )
            ) {
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
            } message: {
                Text("\"\(script.name)\" can't be recovered once deleted.")
            }
    }

    /// ``library/scripts`` narrowed to those whose name contains
    /// ``searchText`` (case-insensitive), or every script when the field is
    /// empty. A typed computed property rather than an inline filter in
    /// ``content``'s `ForEach`, per this view's compiler-timeout history;
    /// see the type doc comment.
    private var filteredScripts: [Script] {
        guard !searchText.isEmpty else { return library.scripts }
        return library.scripts.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// The sort-order `Menu`, published as its own `ToolbarContent` value
    /// rather than inlined into the `.toolbar` closure; see the type doc
    /// comment on why new toolbar content here starts out as a typed
    /// property.
    private var sortMenuToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                sortPicker
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
    }

    /// The sort order choices, shown in ``sortMenuToolbarItem`` on macOS and
    /// as a submenu of ``moreMenuToolbarItem`` on iOS/iPadOS.
    private var sortPicker: some View {
        Picker("Sort By", selection: sortOrderBinding) {
            ForEach(ScriptSortOrder.allCases) { order in
                Text(order.displayName).tag(order)
            }
        }
    }

    #if !os(macOS)
        /// The iOS/iPadOS "…" menu: sort order, Reference and Settings. macOS
        /// reaches Reference and Settings through the app menu (⌘? and ⌘,)
        /// and keeps a separate sort button. One menu rather than separate
        /// buttons because the regular-width sidebar (iPad, unfolded iPhone
        /// Duo) has room for only two items beside the "Scripts" title and
        /// the sidebar toggle. With four, the system overflow swallowed New
        /// Script and Settings; with three, the title truncated to "Scr…".
        private var moreMenuToolbarItem: some ToolbarContent {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Menu {
                        sortPicker
                    } label: {
                        Label("Sort By", systemImage: "arrow.up.arrow.down")
                    }
                    Divider()
                    Button {
                        isPresentingReference = true
                    } label: {
                        Label("Reference", systemImage: "info.circle")
                    }
                    Button {
                        isPresentingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    #endif

    /// A hand-rolled `Binding` into ``ScriptLibrary/sortOrder``, matching the
    /// rest of this view's bindings into VM/optional state (e.g. the rename
    /// sheet's `isPresented` below) rather than reaching for `@Bindable`.
    private var sortOrderBinding: Binding<ScriptSortOrder> {
        Binding(
            get: { library.sortOrder },
            set: { library.sortOrder = $0 }
        )
    }

    /// Resets the new-script name field and shows the naming alert. Shared
    /// by the toolbar button, the empty-state action, and the macOS ⌘N menu
    /// command (via `.focusedSceneValue(\.newScriptAction, ...)` above), so
    /// all three stay in sync with a single implementation.
    private func presentNewScriptAlert() {
        newName = "Untitled"
        isPresentingNewAlert = true
    }

    /// The `newScriptAction` published via `.focusedSceneValue` in ``body``.
    /// It always does the same thing, so its target is a fixed label.
    private var newScriptCommand: ScriptCommandAction {
        ScriptCommandAction(target: "newScript", perform: presentNewScriptAlert)
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
/// with a `TextField`: the alert version reliably opened with an empty
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
            // A plain padded field, not a `Form`. A `Form` here rendered
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
        // Same macOS sheet-sizing issue as `GemListView`: without an
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
/// type so the preview body stays a plain `ViewBuilder`. Seeding a temp-dir
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
