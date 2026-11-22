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
    #if DEBUG
        // The screenshot UI test swaps in a throwaway library, see
        // `ScreenshotFixture`.
        @State private var library = ScreenshotFixture.libraryIfRequested() ?? ScriptLibrary()
    #else
        @State private var library = ScriptLibrary()
    #endif

    var body: some Scene {
        WindowGroup {
            Group {
                #if os(macOS)
                    ScriptListView(library: library)
                        // Deliver links to the open window instead of opening a second one; the app is built around one window (see ScriptCommands).
                        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                        // A fixed size in screenshot mode, which `mainWindowResizability` makes the window follow; nil x nil changes nothing.
                        .frame(
                            width: Self.screenshotWindowSize?.width,
                            height: Self.screenshotWindowSize?.height)
                #else
                    RootTabView(library: library)
                #endif
            }
            // rubycuts://script?name=... from a tapped widget (ScriptLink).
            .onOpenURL { library.handleOpenURL($0) }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // The user can flip notification permission in Settings while the
            // app is backgrounded, so re-read it on every return to the
            // foreground, not just once at launch. There's no request here:
            // permission is asked for just-in-time, from
            // ``NotificationCapability/post(title:body:)``, the first time a
            // script actually calls `Device::Notification.notify`.
            if newPhase == .active {
                Task { await NotificationCapability.refreshAuthorizationStatus() }
            }
        }
        #if os(macOS)
            .commands { ScriptCommands() }
            // Leaves ~640pt for the editor next to the 200-320pt sidebar
            // (see `ScriptListView`'s `navigationSplitViewColumnWidth`).
            // Unavailable on iOS, hence the guard.
            .defaultSize(width: 900, height: 600)
            .windowResizability(Self.mainWindowResizability)
        #endif

        #if os(macOS)
            // A separate window rather than a sheet, so the documentation can
            // sit open beside the editor while you copy from it, reached from
            // Help ▸ RubyCuts Documentation (⌘?), see `ScriptCommands`.
            // iOS/iPadOS instead present `DocumentationView` as a sheet from
            // `ScriptListView`. The id predates the rename and is internal only.
            Window("RubyCuts Documentation", id: "reference") {
                NavigationStack {
                    DocumentationView()
                }
            }
            .defaultSize(width: 560, height: 640)
        #endif

        #if os(macOS)
            // Gives the app ⌘, and the App-menu "Settings…" item for free.
            // No `CommandGroup(replacing: .appSettings)` needed for that,
            // and no custom About either: macOS synthesises one from
            // `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, already set in
            // the project.
            Settings {
                GemSettingsPane(scriptLibrary: library)
            }
        #endif
    }

    #if os(macOS)
        /// The main window's fixed size in screenshot mode (see ``ScreenshotFixture/macWindowSize``), otherwise `nil`.
        private static var screenshotWindowSize: CGSize? {
            #if DEBUG
                ScreenshotFixture.macWindowSize
            #else
                nil
            #endif
        }

        /// `.contentSize` in screenshot mode, so the window takes the content's fixed size even over a frame macOS remembers; the default otherwise.
        private static var mainWindowResizability: WindowResizability {
            screenshotWindowSize == nil ? .automatic : .contentSize
        }
    #endif
}
