import SwiftUI

extension FocusedValues {
    /// Creates a new, untitled script. Published by ``ScriptListView``.
    @Entry var newScriptAction: ScriptCommandAction?

    /// Runs the currently open script. Published by ``ScriptEditorView``,
    /// `nil` while a run is already in progress or nothing has loaded yet.
    @Entry var runScriptAction: ScriptCommandAction?

    /// Cancels the in-flight run. Published by ``ScriptEditorView``, `nil`
    /// unless a run is actually in progress.
    @Entry var stopScriptAction: ScriptCommandAction?

    /// Saves the currently open script. Published by ``ScriptEditorView``,
    /// `nil` while a run is in progress or nothing has loaded yet.
    @Entry var saveScriptAction: ScriptCommandAction?
}

/// A menu command action published through `FocusedValues`.
///
/// A bare closure in an `@Entry` makes SwiftUI treat every body pass as a
/// change, since closures can't be compared. This wrapper compares by
/// ``target`` instead: the thing the action operates on (the open ``Script``
/// for editor actions), so the published value only changes when the action
/// would do something different. The closure may still read `@State`
/// freely, since state is resolved when it runs, not when it's captured.
struct ScriptCommandAction: Equatable {
    /// What the action operates on. Two actions with the same target are
    /// treated as the same action.
    let target: AnyHashable

    /// The work the menu item performs.
    let perform: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target == rhs.target
    }
}

/// macOS menu bar commands for the script actions that otherwise only live
/// as toolbar buttons. Reads the current actions via
/// `@FocusedValue`, which ``ScriptListView`` and ``ScriptEditorView``
/// publish with `.focusedSceneValue`: when an action is `nil` (nothing
/// selected, a run in progress, etc.) the corresponding menu item disables
/// itself for free.
///
/// `@FocusedValue`/`@Entry` on `FocusedValues` needs macOS 15 / iOS 18, well
/// below the project's macOS 26 / iOS 26 floor. If this ever misbehaves, the
/// fallback is hand-written `FocusedValueKey` conformances: four lines
/// each, with identical call sites.
struct ScriptCommands: Commands {
    @FocusedValue(\.newScriptAction) private var newScript
    @FocusedValue(\.runScriptAction) private var runScript
    @FocusedValue(\.stopScriptAction) private var stopScript
    @FocusedValue(\.saveScriptAction) private var saveScript

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Replaces the default New Window item rather than adding alongside
        // it: ⌘N should create a script, and RubyCuts has no per-window
        // state worth a second window of: one library, one selection.
        CommandGroup(replacing: .newItem) {
            Button("New Script") { newScript?.perform() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newScript == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { saveScript?.perform() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(saveScript == nil)
        }
        // Run and Stop are separate items, not one label that toggles
        // between them: a menu reads better with two entries that enable
        // independently than with a label that changes under the cursor.
        CommandMenu("Script") {
            Button("Run") { runScript?.perform() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(runScript == nil)
            Button("Stop") { stopScript?.perform() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(stopScript == nil)
        }
        // Replaces the default Help menu ("RubyCuts Help") rather than
        // adding alongside it: the default item opens a help book this
        // app doesn't ship, which is worse than no item at all.
        CommandGroup(replacing: .help) {
            Button("RubyCuts Reference") { openWindow(id: "reference") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}
