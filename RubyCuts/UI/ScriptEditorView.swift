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
/// The editor holds its own error state (not the list VM's) because an error
/// here is local to the detail surface, not list state. Rename-the-file is out
/// of scope for this slice: the navigation title is the script's current name,
/// read-only.
struct ScriptEditorView: View {
    let script: Script
    let store: ScriptStore

    @State private var source: String = ""
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var showError = false

    /// The last run's captured output, shown in the console panel. `nil` until
    /// the first Run (so the panel stays hidden before then).
    @State private var runResult: RunResult?

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
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    run()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("r", modifiers: .command)
                .help("Run the script (⌘R)")
                .disabled(!didLoad)

                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save the script (⌘S)")
                .disabled(!didLoad)
            }
        }
        .task {
            // Read on demand: source isn't held on the model, only loaded here
            // when the editor appears. A read failure shows an alert rather than
            // crashing the view; the editor opens empty.
            do {
                source = try store.source(of: script)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            didLoad = true
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        do {
            try store.write(script, source: source)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// Runs the current source through the embedded Ruby VM. Synchronous and
    /// on the main actor (the VM is pinned there), so a long script blocks the
    /// UI -- see ``RubyRuntime/run(_:)``'s known-follow-up note. For typical
    /// short scripts the result is instant. The console panel appears with the
    /// captured output.
    private func run() {
        runResult = RubyRuntime.shared.run(source)
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
