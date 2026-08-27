import SwiftUI

@main
struct RubyCutsApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ScriptListView()
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
    }
}
