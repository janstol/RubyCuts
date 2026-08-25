import Foundation
import UserNotifications

/// The `Device::Notification` capability: post a local notification from
/// Ruby. This is the "tell the user something" primitive PRD 3.5 asks for --
/// a local notification rather than a blocking alert, because `RubyRuntime`
/// blocks the main actor for the whole script run (see its doc comment), and
/// because a Shortcut can run a script with the app backgrounded, where only
/// a notification is visible at all.
///
/// Posting is fire-and-forget: `UNUserNotificationCenter.add(_:)` is async,
/// and nothing in `UserNotifications` can be awaited from inside a
/// synchronous Ruby callback, so the script gets back `nil` and can't learn
/// whether delivery actually succeeded. What the handler *can* check
/// synchronously is ``cachedAuthorizationStatus``, refreshed by
/// ``refreshAuthorizationStatus()`` at launch and scene activation -- and it
/// raises an actionable ``NativeBridgeError`` when that cache says
/// notifications are denied or still undetermined, rather than silently
/// posting a request that's certain to be dropped. A cache miss (permission
/// revoked in Settings since the last refresh) still means the script gets
/// no error even though delivery fails -- best-effort by construction.
enum NotificationCapability {
    /// The last-known authorization status, read synchronously by
    /// ``post(title:body:)``. Production code only ever sets this via
    /// ``refreshAuthorizationStatus()``; tests set it directly to drive the
    /// denied-status guard without touching real system permission state.
    @MainActor
    static var cachedAuthorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Re-reads the current authorization status from
    /// `UNUserNotificationCenter` into ``cachedAuthorizationStatus``. Call at
    /// launch (after requesting authorization) and on scene activation, since
    /// the user can flip notification permission in Settings while the app
    /// is backgrounded.
    @MainActor
    static func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        cachedAuthorizationStatus = settings.authorizationStatus
    }

    /// Registers the notify handler on `bridge`.
    @MainActor
    static func register(in bridge: NativeBridge) {
        bridge.register("device.notification.notify") { args in
            guard args.count == 2 else {
                throw NativeBridgeError(
                    message: "device.notification.notify requires a title and a body"
                )
            }
            try post(title: args[0], body: args[1])
            return nil
        }
    }

    /// The Ruby surface this capability adds: `Device::Notification.notify(title, body)`.
    static let preludeSource = """
        module Device
          module Notification
            def self.notify(title, body)
              RubyCuts::Native.invoke("device.notification.notify", title, body)
              nil
            end
          end
        end
        """

    @MainActor
    private static func post(title: String, body: String) throws {
        switch cachedAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            throw NativeBridgeError(
                message:
                    "notifications are denied -- enable them in Settings to use Device::Notification"
            )
        case .notDetermined:
            throw NativeBridgeError(
                message: "notification permission hasn't been granted yet"
            )
        @unknown default:
            throw NativeBridgeError(
                message: "notification authorization status is unknown"
            )
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
