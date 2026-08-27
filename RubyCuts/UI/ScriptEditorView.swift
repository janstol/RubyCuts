import SwiftUI

/// Edits one script's source and runs it. Takes the ``Script`` and the
/// ``ScriptStore`` it lives in (the list view and the preview use the same
/// path), loads source on demand, and saves back on demand -- mirroring Phase
/// 2's "source stays on disk, read when needed" design.
///
/// Running is wired straight into ``RubyRuntime/shared`` via a Run toolbar
/// button: the result populates ``runResult`` and renders in a
/// ``ConsoleOutputView`` panel below the editor. There's no separate console
/// view model -- a passthrough to a singleton would be ceremony, and the
/// console has no state worth observing beyond the last result (yet; live
/// streaming + history would justify extracting one).
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
/// not a reference to the list VM itself. Renaming the file is out of scope
/// here: it's reachable from the list row's context menu instead, and giving
/// the editor's own title a rename affordance (an `onRename` callback) is its
/// own follow-up item.
struct ScriptEditorView: View {
    let script: Script
    let store: ScriptStore

    /// Called when an autosave (triggered by ``onDisappear`` or a
    /// scene-phase change) fails, since the local alert can't be relied on to
    /// be seen at that point. Defaults to a no-op so previews and tests that
    /// don't care about this can ignore it.
    var onSaveError: (String) -> Void = { _ in }

    @State private var source: String = ""

    /// The source as of the last successful save, used only to derive
    /// ``isDirty``. Set alongside `source` when the script loads, and again
    /// on every successful save.
    @State private var savedSource: String = ""
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var isRunning = false

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
        .navigationTitle(script.name)
        #if os(macOS)
            .navigationSubtitle(isDirty ? "Edited" : "")
        #endif
        .toolbar {
            #if !os(macOS)
                // No `navigationSubtitle` on iOS/iPadOS, so the modified
                // marker rides along in a custom title view instead.
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(script.name)
                            .font(.headline)
                        if isDirty {
                            Text("Edited")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            #endif
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    run()
                } label: {
                    if isRunning {
                        ProgressView()
                    } else {
                        Label("Run", systemImage: "play.fill")
                    }
                }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("r", modifiers: .command)
                .help("Run the script (⌘R)")
                .disabled(!didLoad || isRunning)

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
    private func save(silent: Bool = false) {
        do {
            try store.write(script, source: source)
            savedSource = source
            errorMessage = nil
        } catch {
            let message = error.localizedDescription
            if silent {
                onSaveError(message)
            } else {
                errorMessage = message
                showError = true
            }
        }
    }

    /// Runs the current source through the embedded Ruby VM. The VM itself
    /// is still synchronous and on the main actor (see
    /// ``RubyRuntime/run(_:)``'s known-follow-up note), so this only buys a
    /// spinner and a disabled Run/Save pair for the run's duration -- the app
    /// is not responsive or cancellable while it runs, and neither will be
    /// possible until that off-main-actor VM work lands.
    private func run() {
        isRunning = true
        Task {
            // Without this yield, `isRunning` flips true and the VM call
            // below blocks the actor before SwiftUI ever commits a frame, so
            // the spinner is set and cleared within one render pass and never
            // actually appears. Looks removable; isn't.
            await Task.yield()
            runResult = RubyRuntime.shared.run(source)
            isRunning = false
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
            ScriptEditorView(script: script, store: store)
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
