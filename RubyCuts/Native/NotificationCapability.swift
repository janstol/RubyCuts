import Foundation
import UserNotifications

/// The `Device::Notification` capability: post a local notification from
/// Ruby. This is the "tell the user something" primitive:
/// a local notification rather than a blocking alert, because a script runs
/// synchronously inside one call into ``RubyRuntime`` (a plain UI alert would
/// have nothing to interrupt), and because a Shortcut can run a script with
/// the app backgrounded, where only a notification is visible at all.
///
/// Posting is fire-and-forget: `UNUserNotificationCenter.add(_:)` is async,
/// and nothing in `UserNotifications` can be awaited from inside a
/// synchronous Ruby callback, so the script gets back `nil` and can't learn
/// whether delivery actually succeeded. What the handler *can* check
/// synchronously is ``cachedAuthorizationStatus``, refreshed by
/// ``refreshAuthorizationStatus()`` at scene activation, and it raises an
/// actionable ``NativeBridgeError`` when that cache says notifications are
/// denied or still undetermined, rather than silently posting a request
/// that's certain to be dropped. A cache miss (permission revoked in Settings
/// since the last refresh) still means the script gets no error even though
/// delivery fails. Best-effort by construction.
///
/// **Permission is requested just-in-time, not at launch.** There's no
/// notification prompt anywhere in `RubyCutsApp`. The first time a script
/// calls `Device::Notification.notify` while the status is
/// `.notDetermined`, ``post(title:body:)`` kicks off the system request on a
/// detached task and still throws, because the request is async and this
/// call can't await it. The OS prompt then appears once the run returns; a
/// second `Device::Notification.notify` call after the user grants or denies
/// succeeds or fails accordingly.
///
/// **This two-call shape is no longer forced.** It was originally justified
/// by `RubyRuntime` holding the main actor for the whole script run, which
/// left nothing free to show the permission sheet mid-run. Now that
/// `RubyRuntime` runs on its own dedicated thread (see its doc comment), the
/// main actor is free while a script runs, so `post(title:body:)` could
/// instead block the VM thread awaiting the request directly and turn this
/// into one call. Left as a follow-up rather than folded into the threading
/// change that unblocked it: that would mix a UX change into a pure
/// threading change.
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
    /// `nonisolated` so `NativeBridge.preludeSource` can read it from the VM
    /// thread with no main-actor hop: it's a plain `String` constant.
    nonisolated static let preludeSource = """
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
                    "notifications are denied. Enable them in Settings to use Device::Notification"
            )
        case .notDetermined:
            // Permission is asked for just-in-time, on the first call, rather
            // than at launch (see `RubyCutsApp`). Nothing in `UserNotifications`
            // can be awaited from here. `post` runs synchronously from inside
            // a Ruby callback on the VM thread, and this function itself isn't
            // async, so the request is kicked off detached and this call
            // still has to fail. The OS prompt appears once the request
            // resolves; a second `Device::Notification.notify` call after
            // granting succeeds. (This could become one call now that the VM
            // thread is free to await the request directly; see this type's
            // doc comment.)
            Task.detached {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                await refreshAuthorizationStatus()
            }
            throw NativeBridgeError(
                message:
                    "requesting notification permission. Allow it, then run the script again"
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
