import SwiftUI

@main
struct RubyCutsApp: App {
    @Environment(\.scenePhase) private var scenePhase

    /// The one script library for the whole app, matching what
    /// ``ScriptCommands`` already assumes ("one library, one selection").
    /// Lives here (not inside ``ScriptListView``) because macOS's Settings
    /// window is a separate scene from the main window, and both need to
    /// share this same instance so a restore in Settings is reflected in the
    /// list without a relaunch.
    @State private var library = ScriptLibrary()

    var body: some Scene {
        WindowGroup {
            ScriptListView(library: library)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // The user can flip notification permission in Settings while the
            // app is backgrounded, so re-read it on every return to the
            // foreground -- not just once at launch. There's no request here:
            // permission is asked for just-in-time, from
            // ``NotificationCapability/post(title:body:)``, the first time a
            // script actually calls `Device::Notification.notify`.
            if newPhase == .active {
                Task { await NotificationCapability.refreshAuthorizationStatus() }
            }
        }
        #if os(macOS)
            .commands { ScriptCommands() }
            // Leaves ~680pt for the editor next to the 180-320pt sidebar
            // (see `ScriptListView`'s `navigationSplitViewColumnWidth`).
            // Unavailable on iOS, hence the guard.
            .defaultSize(width: 900, height: 600)
        #endif

        #if os(macOS)
            // A separate window rather than a sheet, so the reference can sit
            // open beside the editor while you copy from it -- reached from
            // Help ▸ RubyCuts Reference (⌘?), see `ScriptCommands`. iOS/iPadOS
            // instead present `ReferenceView` as a sheet from `ScriptListView`.
            Window("RubyCuts Reference", id: "reference") {
                NavigationStack {
                    ReferenceView()
                }
            }
            .defaultSize(width: 480, height: 600)
        #endif

        #if os(macOS)
            // Gives the app ⌘, and the App-menu "Settings…" item for free.
            // No `CommandGroup(replacing: .appSettings)` needed for that,
            // and no custom About either -- macOS synthesises one from
            // `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, already set in
            // the project.
            Settings {
                GemSettingsPane(scriptLibrary: library)
            }
        #endif
    }
}
