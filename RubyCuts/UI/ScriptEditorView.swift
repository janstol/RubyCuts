import SwiftUI

/// Edits one script's source and runs it. Takes the ``Script`` and the
/// ``ScriptStore`` it lives in (the list view and the preview use the same
/// path), loads source on demand, and saves back on demand -- mirroring Phase
/// 2's "source stays on disk, read when needed" design.
///
/// Running is wired straight into ``RubyRuntime/shared`` via a Run toolbar
/// button, which becomes a Stop button for the run's duration: the result
/// populates ``runResult`` and renders in a ``ConsoleOutputView`` panel below
/// the editor. There's no separate console view model -- a passthrough to a
/// singleton would be ceremony, and the console has no state worth observing
/// beyond the last result (yet; live streaming + history would justify
/// extracting one).
///
/// **Save model:** edits autosave, they aren't confirmed-on-leave.
/// `NavigationStack`'s back button and the iOS interactive back-swipe can't
/// be reliably intercepted to run a confirmation, so rather than fight that,
/// the editor saves automatically when it disappears or when the scene
/// leaves `.active` (backgrounding), in addition to the explicit ⌘S button,
/// which stays as the discoverable affordance and the macOS convention.
/// ``isDirty`` drives an "Edited" marker next to the title so the state is
/// visible before either trigger fires. An autosave failure can't use the
/// local error alert -- the view may already be leaving -- so it's reported
/// through ``onSaveError`` instead, which the list view wires to
/// ``ScriptLibrary/errorMessage``; an explicit-save failure still uses the
/// local alert, since the editor is guaranteed visible when that happens.
///
/// The editor holds its own error state (not the list VM's) because an error
/// here is local to the detail surface, not list state -- ``onSaveError`` is
/// a narrow, one-directional exception to that for the autosave case above,
/// not a reference to the list VM itself. Renaming is also reachable here on
/// iOS/iPadOS, through the editable navigation title, in addition to the
/// list row's context menu. macOS doesn't get a title-based rename
/// affordance -- confirmed live that neither a plain editable title binding
/// nor `.navigationDocument` unlocks one outside a `DocumentGroup` app -- so
/// there the context menu (a sheet, not an alert; see
/// `ScriptListView.RenameSheet`) is the only rename path.
struct ScriptEditorView: View {
    let script: Script
    let store: ScriptStore

    /// Called when an autosave (triggered by ``onDisappear`` or a
    /// scene-phase change) fails, since the local alert can't be relied on to
    /// be seen at that point. Defaults to a no-op so previews and tests that
    /// don't care about this can ignore it.
    var onSaveError: (String) -> Void = { _ in }

    /// Called when the user commits a new name in the editable title
    /// (iOS/iPadOS only -- see the type doc comment). Returns the renamed
    /// ``Script`` on success and `nil` on failure -- the list view owns the
    /// store mutation and surfaces the error, and `nil` tells the editor to
    /// revert the title text. Defaults to a no-op that always fails, so
    /// previews and tests that don't wire it simply can't rename.
    var onRename: (String) -> Script? = { _ in nil }

    @State private var source: String = ""

    /// The name shown in the editable navigation title on iOS/iPadOS. Seeded
    /// from `script.name` and committed through ``onRename`` when the user
    /// finishes editing it. Unused on macOS, where the title is static.
    @State private var editableName = ""

    /// The source as of the last successful save, used only to derive
    /// ``isDirty``. Set alongside `source` when the script loads, and again
    /// on every successful save.
    @State private var savedSource: String = ""
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var isRunning = false

    /// The in-flight run's `Task`, held only so the Stop button can cancel
    /// it. `nil` whenever no run is in progress.
    @State private var runTask: Task<Void, Never>?

    @Environment(\.scenePhase) private var scenePhase

    /// The last run's captured output, shown in the console panel. `nil` until
    /// the first Run (so the panel stays hidden before then).
    @State private var runResult: RunResult?

    /// Whether `source` has unsaved changes. `false` before the initial load
    /// completes, so the "Edited" marker can't flash on briefly while the
    /// `.task` below is still populating `source`.
    private var isDirty: Bool {
        didLoad && source != savedSource
    }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.none)
                #endif
                .frame(maxHeight: .infinity)

            if let runResult {
                Divider()
                ConsoleOutputView(result: runResult)
                    .frame(maxHeight: 220)
                    .background(.regularMaterial)
            }
        }
        #if os(macOS)
            // An editable `.navigationTitle` binding doesn't get a
            // click-to-rename affordance here -- confirmed live, and
            // `.navigationDocument` doesn't unlock it either. Apple's docs
            // scope `.navigationDocument` to document-based (`DocumentGroup`)
            // apps; RubyCuts is a plain `WindowGroup`, and making it one
            // is a much bigger change than this item. So the title stays
            // static on macOS, and the context-menu rename (now a sheet,
            // see `ScriptListView.RenameSheet`) is the only rename path
            // there.
            .navigationTitle(script.name)
            .navigationSubtitle(isDirty ? "Edited" : "")
        #else
            // On iOS/iPadOS an editable title binding does present a
            // click/tap-to-rename affordance without needing
            // `.navigationDocument`.
            .navigationTitle($editableName)
            .onChange(of: editableName) { _, newValue in commitRename(to: newValue) }
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                #if !os(macOS)
                    // No `navigationSubtitle` on iOS/iPadOS, so the modified
                    // marker rides along in the toolbar instead, now that the
                    // title itself is an editable binding.
                    if isDirty {
                        Text("Edited")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                #endif
                if isRunning {
                    ProgressView()
                    Button {
                        runTask?.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .tint(.red)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop the running script (⌘.)")
                } else {
                    Button {
                        run()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Run the script (⌘R)")
                    .disabled(!didLoad)
                }

                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save the script (⌘S)")
                .disabled(!didLoad || isRunning)
            }
        }
        .task {
            // Read on demand: source isn't held on the model, only loaded here
            // when the editor appears. A read failure shows an alert rather than
            // crashing the view; the editor opens empty.
            editableName = script.name
            do {
                source = try store.source(of: script)
                savedSource = source
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            didLoad = true
        }
        .onDisappear {
            if isDirty {
                save(silent: true)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // `onDisappear` doesn't fire when the app is backgrounded while
            // this view stays on screen (e.g. the user leaves without
            // navigating away), so autosave on the scene leaving `.active`
            // too.
            if newPhase != .active && isDirty {
                save(silent: true)
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Writes `source` to disk. `silent` distinguishes an autosave (the view
    /// may be disappearing, so the local alert may never be seen -- report
    /// through ``onSaveError`` instead) from the explicit Save button (the
    /// editor is guaranteed visible, so the local alert works as before).
    /// Returns whether the save succeeded, so ``commitRename(to:)`` can tell
    /// whether it's safe to move the file out from under the old URL.
    ///
    /// A silent autosave first checks that `script.url` still exists.
    /// Renaming or deleting the open script from the list changes `selection`,
    /// which tears this view down via `.id(selection)` -- but that happens
    /// *after* the file's already moved or gone, so `.onDisappear`'s autosave
    /// would otherwise write to a stale path and resurrect a phantom copy of
    /// a script that was just renamed or deleted out from under it (confirmed
    /// live: a rename left a duplicate file that only showed up after an app
    /// restart triggered a fresh directory scan). Skipping is strictly better
    /// than that: at worst it loses the last few keystrokes in that narrow
    /// race, which is the same tradeoff "autosave, not confirm-on-leave"
    /// already accepts everywhere else, not new data loss.
    @discardableResult
    private func save(silent: Bool = false) -> Bool {
        if silent && !FileManager.default.fileExists(atPath: script.url.path) {
            return true
        }
        do {
            try store.write(script, source: source)
            savedSource = source
            errorMessage = nil
            return true
        } catch {
            let message = error.localizedDescription
            if silent {
                onSaveError(message)
            } else {
                errorMessage = message
                showError = true
            }
            return false
        }
    }

    /// Commits an edit to ``editableName`` as a rename. Order matters here:
    /// a rename moves the file out from under `script.url`, so unsaved
    /// source has to reach the *old* URL first, before ``onRename`` moves it.
    private func commitRename(to newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != script.name else {
            editableName = script.name
            return
        }
        if isDirty {
            guard save() else {
                // Renaming on top of a failed save would strand the edits
                // under a URL nothing points at anymore.
                editableName = script.name
                return
            }
        }
        if onRename(trimmed) == nil {
            editableName = script.name
        }
    }

    /// Runs the current source through the embedded Ruby VM. `RubyRuntime`
    /// runs on its own dedicated thread now (see its doc comment), so
    /// `await`ing it here suspends this task rather than blocking the main
    /// actor -- the window stays draggable, the list stays scrollable, and
    /// the spinner keeps animating for the whole run.
    ///
    /// Cancellable via the Stop button that replaces Run while `isRunning`:
    /// cancelling ``runTask`` trips ``RubyRuntime/runCancellable(_:input:)``'s
    /// `onCancel` handler, which is what actually stops the VM -- this method
    /// itself only starts and tracks the task. Per ``RubyRuntime``'s doc
    /// comment, that stop only lands at the next Ruby-level checkpoint, so a
    /// script blocked inside a single C call (`sleep`, a network read) keeps
    /// running until that call returns.
    private func run() {
        isRunning = true
        runTask = Task {
            runResult = await RubyRuntime.shared.runCancellable(source)
            isRunning = false
            runTask = nil
        }
    }
}

#Preview {
    ScriptEditorPreview()
}

/// Backing view for ``ScriptEditorView``'s `#Preview`. Extracted into its own
/// type so the preview body stays a plain `ViewBuilder` -- the I/O setup (a
/// temp-dir store + a seeded script) is local file I/O, allowed in previews
/// per the repo convention, but mixing `try?` and optionals into the preview
/// closure overloads the typechecker.
private struct ScriptEditorPreview: View {
    @State private var script: Script
    private let store: ScriptStore

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsPreview-\(UUID().uuidString)")
        let store = ScriptStore(directoryURL: dir)
        try? store.ensureDirectory()
        self.store = store
        self._script = State(
            initialValue: (try? store.create(name: "hello", source: "puts 'hello, world'"))
                ?? Script(url: dir.appending(component: "hello.rb"))
        )
    }

    var body: some View {
        NavigationStack {
            ScriptEditorView(
                script: script,
                store: store,
                onRename: { newName in
                    guard let renamed = try? store.rename(script, to: newName) else {
                        return nil
                    }
                    script = renamed
                    return renamed
                }
            )
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
