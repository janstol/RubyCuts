import SwiftUI

/// Edits one script's source and runs it. Takes the ``Script`` and the
/// ``ScriptStore`` it lives in (the list view and the preview use the same
/// path), loads source on demand, and saves back on demand, mirroring Phase
/// 2's "source stays on disk, read when needed" design.
///
/// Running is wired straight into ``RubyRuntime/shared`` via a Run toolbar
/// button, which becomes a Stop button for the run's duration: the result
/// populates ``runResult`` and renders in a ``ConsoleOutputView`` panel below
/// the editor. There's no separate console view model: a passthrough to a
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
/// local error alert, since the view may already be leaving, so it's reported
/// through ``onSaveError`` instead, which the list view wires to
/// ``ScriptLibrary/errorMessage``; an explicit-save failure still uses the
/// local alert, since the editor is guaranteed visible when that happens.
///
/// The editor holds its own error state (not the list VM's) because an error
/// here is local to the detail surface, not list state. ``onSaveError`` is
/// a narrow, one-directional exception to that for the autosave case above,
/// not a reference to the list VM itself. Renaming is also reachable here on
/// iOS/iPadOS, through the editable navigation title, in addition to the
/// list row's context menu. macOS doesn't get a title-based rename
/// affordance. Confirmed live that neither a plain editable title binding
/// nor `.navigationDocument` unlocks one outside a `DocumentGroup` app, so
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

    /// Called after a *successful* save (autosave or the explicit button),
    /// so the list view can refresh and pick up the new ``Script/modifiedAt``.
    /// Defaults to a no-op so previews and tests that don't wire it are
    /// unaffected.
    var onSaved: () -> Void = {}

    /// Called when the user commits a new name in the editable title
    /// (iOS/iPadOS only; see the type doc comment). Returns the renamed
    /// ``Script`` on success and `nil` on failure: the list view owns the
    /// store mutation and surfaces the error, and `nil` tells the editor to
    /// revert the title text. Defaults to a no-op that always fails, so
    /// previews and tests that don't wire it simply can't rename.
    var onRename: (String) -> Script? = { _ in nil }

    /// Installs this editor's pending-save hook with the owner, or removes it
    /// when passed `nil`. The sidebar's rename needs a way to flush the
    /// buffer that lives here as `@State` and is otherwise unreachable from
    /// the list. Defaults to a no-op so previews and tests that don't wire
    /// it are unaffected.
    var onFlushHookChange: ((() -> Bool)?) -> Void = { _ in }

    /// The editor buffer. An `AttributedString` rather than a `String` so
    /// ``RubySyntaxHighlighting`` can color it in place (attribute-only, the
    /// characters are the script); everything that needs the plain source
    /// reads ``sourceText``.
    @State private var source = AttributedString()

    /// The characters `source` held the last time it was highlighted. Lets
    /// ``rehighlight()`` tell a real edit from its own attribute-only
    /// re-coloring, which also fires `onChange`.
    @State private var lastHighlightedText = ""

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
    /// the first Run (so the panel stays hidden before then), and set back to
    /// `nil` by the console's Clear button.
    @State private var runResult: RunResult?

    /// The console panel's height, dragged via ``ConsoleResizeHandle``.
    /// `@AppStorage`, not the injected-`UserDefaults` seam ``ScriptLibrary``
    /// uses elsewhere. This is per-view chrome with no test surface and no
    /// view model to hang it on, so threading a `UserDefaults` down here
    /// would be abstraction the case doesn't need.
    @AppStorage("consoleHeight") private var consoleHeight: Double = 220

    /// The minimum height the console panel can shrink to, and the minimum
    /// height reserved for the editor above it, before the resize handle's
    /// own space is subtracted from `available`. `@ScaledMetric` rather than
    /// a plain constant, so both grow with Dynamic Type. At AX5, the
    /// console header alone exceeds a fixed 100pt, and a fixed minimum would
    /// leave the body scroll view no room at all.
    @ScaledMetric(relativeTo: .body) private var minConsoleHeight: Double = 100
    @ScaledMetric(relativeTo: .body) private var minEditorHeight: Double = 100

    /// Whether `source` has unsaved changes. `false` before the initial load
    /// completes, so the "Edited" marker can't flash on briefly while the
    /// `.task` below is still populating `source`.
    private var isDirty: Bool {
        didLoad && sourceText != savedSource
    }

    /// The plain characters of ``source``, without highlighting attributes:
    /// what gets saved, run, and compared against ``savedSource``.
    private var sourceText: String {
        String(source.characters)
    }

    var body: some View {
        editorContent
            .toolbar { editorToolbar }
            .focusedSceneValue(\.runScriptAction, runAction)
            .focusedSceneValue(\.stopScriptAction, stopAction)
            .focusedSceneValue(\.saveScriptAction, saveAction)
            .task {
                // Read on demand: source isn't held on the model, only
                // loaded here when the editor appears. A read failure shows
                // an alert rather than crashing the view; the editor opens
                // empty.
                editableName = script.name
                do {
                    let text = try store.source(of: script)
                    source = RubySyntaxHighlighting.highlighted(text)
                    savedSource = text
                    lastHighlightedText = text
                } catch {
                    errorMessage = error.localizedDescription
                    showError = true
                }
                didLoad = true
                // Registered only after the load completes: handing out a
                // hook over an empty `source` would let a rename that lands
                // mid-load flush nothing and overwrite the real file.
                onFlushHookChange(flushForRename)
            }
            .onDisappear {
                // Deregister before the autosave below: once this view is
                // going away, the library must stop reaching for a hook
                // whose `save()` is about to run its own last time anyway.
                onFlushHookChange(nil)
                if isDirty {
                    save(silent: true)
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                // `onDisappear` doesn't fire when the app is backgrounded
                // while this view stays on screen (e.g. the user leaves
                // without navigating away), so autosave on the scene
                // leaving `.active` too.
                if newPhase != .active && isDirty {
                    save(silent: true)
                }
            }
            .onChange(of: source) { _, _ in rehighlight() }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    /// The editor's on-screen content: the text view, the console panel
    /// when a run has produced output, and the navigation title. Split out
    /// of ``body`` so the type-checker isn't asked to solve this together
    /// with the toolbar and the rest of ``body``'s modifiers in one pass.
    /// Combined, that expression was slow enough to time out.
    private var editorContent: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                TextEditor(text: $source)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.none)
                    #endif
                    // Breathing room between the code and the split divider
                    // and the toolbar. Safe-area padding rather than plain
                    // padding, so the scroll view itself still runs edge to
                    // edge and the toolbar's scroll edge effect keeps
                    // covering it. (`contentMargins(for: .scrollContent)` is
                    // ignored by the attributed editor; the safe area is
                    // what it turns into scroll insets, confirmed live.)
                    .safeAreaPadding(.horizontal, 12)
                    .safeAreaPadding(.top, 8)
                    .frame(maxHeight: .infinity)
                    .background(editorAppearanceFix)
                    .accessibilityLabel("Script Source")

                if let runResult {
                    ConsoleResizeHandle(
                        height: $consoleHeight,
                        bounds: consoleHeightBounds(in: proxy.size.height)
                    )
                    ConsoleOutputView(result: runResult, onClear: { self.runResult = nil })
                        .frame(height: clampedConsoleHeight(in: proxy.size.height))
                        .background(.regularMaterial)
                }
            }
        }
        #if os(macOS)
            // An editable `.navigationTitle` binding doesn't get a
            // click-to-rename affordance here. Confirmed live, and
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
    }

    /// The macOS-only workaround for the attributed `TextEditor` pinning its
    /// scroll view to the light appearance; see ``TextEditorAppearanceFix``.
    /// Nothing on iOS. A typed property rather than an inline `#if` in the
    /// modifier chain, per this view's type-checker history.
    @ViewBuilder
    private var editorAppearanceFix: some View {
        #if os(macOS)
            TextEditorAppearanceFix()
        #else
            EmptyView()
        #endif
    }

    /// The resize handle's own laid-out height. See
    /// ``ConsoleResizeHandle``'s doc comment for why that stays a fixed 8pt
    /// on every platform even though its *hit target* grows on iOS/iPadOS.
    private static let resizeHandleHeight: Double = 8

    /// The range ``ConsoleResizeHandle`` may drag ``consoleHeight`` within,
    /// given `available` (the editor content's total height from
    /// `GeometryReader`). Extracted into its own typed function rather than
    /// inlined in the view body. This view has documented type-checker
    /// fragility (see ``editorToolbar``'s doc comment), so new conditional
    /// or arithmetic expressions get pulled out, not inlined.
    private func consoleHeightBounds(in available: CGFloat) -> ClosedRange<Double> {
        let maxHeight = max(
            minConsoleHeight,
            Double(available) - minEditorHeight - Self.resizeHandleHeight
        )
        return minConsoleHeight...maxHeight
    }

    /// ``consoleHeight`` clamped into ``consoleHeightBounds(in:)`` for
    /// `available`. Reading `consoleHeight` back through the clamp (rather
    /// than trusting the stored value directly) is what keeps a height
    /// dragged tall on a big window from squeezing the editor to nothing
    /// after the window, or the whole app on a small iPhone, shrinks.
    private func clampedConsoleHeight(in available: CGFloat) -> CGFloat {
        let bounds = consoleHeightBounds(in: available)
        return CGFloat(min(max(consoleHeight, bounds.lowerBound), bounds.upperBound))
    }

    /// The `runScriptAction` published via `.focusedSceneValue` in ``body``.
    /// A computed property with an explicit type, rather than an inline
    /// ternary in the modifier chain, so the type-checker doesn't have to
    /// solve it together with the rest of that chain. See
    /// ``editorToolbar``'s doc comment for the same issue elsewhere in this
    /// view. Mirrors the Run button's `.disabled(!didLoad)`.
    private var runAction: ScriptCommandAction? {
        guard didLoad && !isRunning else { return nil }
        return ScriptCommandAction(target: script, perform: run)
    }

    /// The `stopScriptAction` published via `.focusedSceneValue` in
    /// ``body``. See ``runAction``'s doc comment for why this is a typed
    /// property rather than an inline ternary.
    private var stopAction: ScriptCommandAction? {
        guard isRunning else { return nil }
        return ScriptCommandAction(target: script) { runTask?.cancel() }
    }

    /// The `saveScriptAction` published via `.focusedSceneValue` in
    /// ``body``. See ``runAction``'s doc comment for why this is a typed
    /// property rather than an inline ternary. Mirrors the Save button's
    /// `.disabled(!didLoad || isRunning)`.
    private var saveAction: ScriptCommandAction? {
        guard didLoad && !isRunning else { return nil }
        return ScriptCommandAction(target: script) { save() }
    }

    /// The toolbar's contents: Run (or a spinner plus Stop while a run is in
    /// flight) as the prominent action, then a fixed spacer so Save sits in
    /// its own glass platter rather than sharing a pill with Run. Extracted
    /// out of ``body`` and split into typed pieces: inlined directly into
    /// the toolbar builder, the mix of `#if` and `if`/`else` branches
    /// alongside the individual buttons below was slow enough for the
    /// compiler to give up type-checking it.
    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        #if !os(macOS)
            // No `navigationSubtitle` on iOS/iPadOS, so the modified marker
            // rides along in the toolbar instead, now that the title itself
            // is an editable binding.
            if isDirty {
                ToolbarItem(placement: .primaryAction) {
                    Text("Edited")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        #endif
        ToolbarItemGroup(placement: .primaryAction) {
            runControls
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            saveButton
        }
    }

    /// Run before a run starts; a spinner and Stop while one is in flight.
    /// See ``editorToolbar``'s doc comment for why this is its own property.
    @ViewBuilder
    private var runControls: some View {
        if isRunning {
            ProgressView()
                .accessibilityLabel("Running")
            stopButton
        } else {
            runButton
        }
    }

    /// See ``editorToolbar``'s doc comment for why this is its own
    /// property.
    private var stopButton: some View {
        Button {
            runTask?.cancel()
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.glassProminent)
        // Orange, not red: cancelling a run isn't destructive, and red is
        // reserved for the console's "Failed" badge.
        .tint(.orange)
        #if !os(macOS)
            // On macOS this shortcut is owned by the ⌘. menu item in
            // `ScriptCommands`; registering it here too would leave
            // AppKit two bindings for one key.
            .keyboardShortcut(".", modifiers: .command)
        #endif
        .help("Stop the running script (⌘.)")
    }

    /// See ``stopButton``'s doc comment for why this is its own property.
    private var runButton: some View {
        Button {
            run()
        } label: {
            Label("Run", systemImage: "play.fill")
        }
        .labelStyle(.titleAndIcon)
        // The one prominent control in the window: accent-tinted glass reads
        // as "the thing to press", while Save and the sidebar's items stay
        // plain glass.
        .buttonStyle(.glassProminent)
        #if !os(macOS)
            .keyboardShortcut("r", modifiers: .command)
        #endif
        .help("Run the script (⌘R)")
        .disabled(!didLoad)
    }

    /// See ``stopButton``'s doc comment for why this is its own property.
    private var saveButton: some View {
        Button {
            save()
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
                // A text-only label gets no glyph inset, so without this the
                // word hugs the edges of its glass platter.
                .padding(.horizontal, 6)
        }
        // Title only: SF Symbols has no glyph that says "save" without also
        // saying "download" (or naming a piece of hardware), and an icon next
        // to Run's made the toolbar read heavy. The `Label` stays so the
        // accessibility name and the menu item keep their symbol.
        .labelStyle(.titleOnly)
        #if !os(macOS)
            .keyboardShortcut("s", modifiers: .command)
        #endif
        .help("Save the script (⌘S)")
        .disabled(!didLoad || isRunning)
    }

    /// Writes `source` to disk. `silent` distinguishes an autosave (the view
    /// may be disappearing, so the local alert may never be seen; report
    /// through ``onSaveError`` instead) from the explicit Save button (the
    /// editor is guaranteed visible, so the local alert works as before).
    /// Returns whether the save succeeded, so ``flushForRename()`` can tell
    /// the library whether it's safe to move the file out from under the
    /// old URL.
    ///
    /// A silent autosave first checks that `script.url` still exists.
    /// Renaming or deleting the open script from the list changes `selection`,
    /// which tears this view down via `.id(selection)`. But that happens
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
            let text = sourceText
            try store.write(script, source: text)
            savedSource = text
            errorMessage = nil
            onSaved()
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

    /// Writes any unsaved source to disk so a rename started elsewhere (the
    /// sidebar's context menu) moves the edits along with the file. `true`
    /// when it is safe to move.
    ///
    /// Silent, so a failure reports through ``onSaveError`` and the list's
    /// single alert, rather than racing a second alert from this view while
    /// the rename sheet dismisses.
    ///
    /// Captures `self` once, at registration time in ``body``'s `.task`.
    /// That's safe for everything `save()` touches: `source`, `savedSource`,
    /// and the other properties it reads/writes are all `@State` or `let`,
    /// and a `@State` read goes through a box keyed by this view's identity:
    /// `.id(selection)` in `ScriptListView` makes that identity
    /// per-script, so the closure keeps reaching the right instance's state
    /// even though the `View` value itself is long gone by the time the
    /// hook runs. It would *not* be safe if this ever read `@Environment` or
    /// `@ScaledMetric`: those are resolved from the environment at the point
    /// of use, not stored in the per-identity box, so a captured read of
    /// either would freeze at the environment in effect when the hook was
    /// registered.
    private func flushForRename() -> Bool {
        guard isDirty else { return true }
        return save(silent: true)
    }

    /// Re-runs the highlighter after a text change. Attribute-only edits
    /// (our own re-coloring) also fire `onChange`, so bail when the
    /// characters are unchanged; that both stops the feedback loop and
    /// avoids double work per keystroke. A full re-tokenize per keystroke is
    /// O(n) and fast for script-sized inputs; no debounce until a manual
    /// pass shows latency.
    private func rehighlight() {
        let text = sourceText
        guard text != lastHighlightedText else { return }
        lastHighlightedText = text
        RubySyntaxHighlighting.apply(to: &source)
    }

    /// Commits an edit to ``editableName`` as a rename. The pending-save
    /// hook registered with ``ScriptLibrary`` (see ``flushForRename()``)
    /// covers flushing unsaved source to the *old* URL before ``onRename``
    /// moves it, the same as it does for the sidebar's rename, so this has
    /// only the name to validate and the revert-on-failure to handle.
    private func commitRename(to newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != script.name else {
            editableName = script.name
            return
        }
        if onRename(trimmed) == nil {
            editableName = script.name
        }
    }

    /// Runs the current source through the embedded Ruby VM. `RubyRuntime`
    /// runs on its own dedicated thread now (see its doc comment), so
    /// `await`ing it here suspends this task rather than blocking the main
    /// actor. The window stays draggable, the list stays scrollable, and
    /// the spinner keeps animating for the whole run.
    ///
    /// Cancellable via the Stop button that replaces Run while `isRunning`:
    /// cancelling ``runTask`` trips ``RubyRuntime/runCancellable(_:input:)``'s
    /// `onCancel` handler, which is what actually stops the VM; this method
    /// itself only starts and tracks the task. Per ``RubyRuntime``'s doc
    /// comment, that stop only lands at the next Ruby-level checkpoint, so a
    /// script blocked inside a single C call (`sleep`, a network read) keeps
    /// running until that call returns.
    private func run() {
        isRunning = true
        runTask = Task {
            runResult = await RubyRuntime.shared.runCancellable(sourceText)
            isRunning = false
            runTask = nil
        }
    }
}

#Preview {
    ScriptEditorPreview()
}

/// Backing view for ``ScriptEditorView``'s `#Preview`. Extracted into its own
/// type so the preview body stays a plain `ViewBuilder`. The I/O setup (a
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
