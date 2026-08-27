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
/// ``refreshAuthorizationStatus()`` at scene activation -- and it raises an
/// actionable ``NativeBridgeError`` when that cache says notifications are
/// denied or still undetermined, rather than silently posting a request
/// that's certain to be dropped. A cache miss (permission revoked in Settings
/// since the last refresh) still means the script gets no error even though
/// delivery fails -- best-effort by construction.
///
/// **Permission is requested just-in-time, not at launch.** There's no
/// notification prompt anywhere in `RubyCutsApp` -- the first time a script
/// calls `Device::Notification.notify` while the status is
/// `.notDetermined`, ``post(title:body:)`` kicks off the system request on a
/// detached task and still throws, because the request is async and this
/// call can't await it. The OS prompt then appears once the run returns and
/// the main actor is free to show it; a second `Device::Notification.notify`
/// call after the user grants or denies succeeds or fails accordingly. This
/// two-call shape is a real user-visible consequence of `RubyRuntime` running
/// the VM on the main actor (see its doc comment's known follow-up), not a
/// bug to hide.
enum NotificationCapability {
    /// The last-known authorization status, read synchronously by
    /// ``post(title:body:)``. Production code only ever sets this via
    /// ``refreshAuthorizationStatus()``; tests set it directly to drive the
    /// denied-status guard without touching real system permission state.
    @MainActor
    static var cachedAuthorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Re-reads the current authorization status from
    /// `UNUserNotificationCenter` into ``cachedAuthorizationStatus``. Call on
    /// scene activation, since the user can flip notification permission in
    /// Settings while the app is backgrounded, and after the just-in-time
    /// request in ``post(title:body:)`` resolves.
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
            // Permission is asked for just-in-time, on the first call, rather
            // than at launch (see `RubyCutsApp`). Nothing in `UserNotifications`
            // can be awaited from here -- `post` runs synchronously from inside
            // a Ruby callback while `RubyRuntime` holds the main actor for the
            // whole run (see this type's doc comment) -- so the request is
            // kicked off detached and this call still has to fail. The OS
            // prompt appears once the run returns and the main actor is free;
            // a second `Device::Notification.notify` call after granting
            // succeeds.
            Task.detached {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                await refreshAuthorizationStatus()
            }
            throw NativeBridgeError(
                message:
                    "requesting notification permission -- allow it, then run the script again"
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
