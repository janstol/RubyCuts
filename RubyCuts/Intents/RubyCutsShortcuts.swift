import AppIntents

/// The App Intents discovery point: declares RubyCuts's two intents in the
/// Shortcuts action gallery so a user can find and add them. No Info.plist key
/// or entitlement is needed: the framework auto-discovers an
/// `AppShortcutsProvider` in the app target (which uses
/// `GENERATE_INFOPLIST_FILE = YES`), so this type is the entire registration.
///
/// `phrases` carry the `\(...)` app-name shortcut that lets Shortcuts expose
/// them as spoken/typed phrases; the `shortTitle` is what shows in the gallery
/// tile, `systemImageName` the SF Symbol on it. Both intents share the multi-
/// platform app target, so they're available on iOS/iPadOS/macOS from one file.
struct RubyCutsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunInlineRubyIntent(),
            phrases: [
                "Run inline Ruby in \(.applicationName)",
                "Run Ruby code in \(.applicationName)",
            ],
            shortTitle: "Run Inline Ruby",
            systemImageName: "curlybraces"
        )

        AppShortcut(
            intent: RunRubyScriptIntent(),
            phrases: [
                "Run a Ruby script in \(.applicationName)",
                "Run Ruby script in \(.applicationName)",
            ],
            shortTitle: "Run Ruby Script",
            systemImageName: "doc.text"
        )
    }
}
