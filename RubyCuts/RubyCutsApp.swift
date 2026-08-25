import SwiftUI
import UserNotifications

@main
struct RubyCutsApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ScriptListView()
                .task {
                    await requestNotificationAuthorization()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // The user can flip notification permission in Settings while the
            // app is backgrounded, so re-read it on every return to the
            // foreground -- not just once at launch.
            if newPhase == .active {
                Task { await NotificationCapability.refreshAuthorizationStatus() }
            }
        }
    }

    /// Requests notification authorization once at launch, then refreshes
    /// ``NotificationCapability``'s cached status from the answer.
    /// `UNUserNotificationCenter` only ever prompts the user once -- a repeat
    /// call just returns the stored answer -- so calling this on every launch
    /// is harmless.
    ///
    /// Tradeoff: this puts a notification permission prompt on first launch
    /// of an app whose main job isn't notifications. A just-in-time
    /// affordance (asking only when a script first calls
    /// `Device::Notification.notify`) would be nicer UX but needs UI this
    /// slice doesn't otherwise touch.
    private func requestNotificationAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        await NotificationCapability.refreshAuthorizationStatus()
    }
}
