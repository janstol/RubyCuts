import Foundation
@testable import RubyCuts
import Testing
import UserNotifications

// What Device::* does in the widget extension. The tests run inside the app, so they check the per-host decisions directly, plus one round trip through Ruby with the widget-host handlers swapped in.
struct ScriptHostTests {
    @Test func theTestHostIsTheApp() {
        #expect(ScriptHost.current == .app)
    }

    @Test func clipboardIsOnlyAvailableInTheApp() {
        #expect(ClipboardCapability.isAvailable(in: .app))
        #expect(!ClipboardCapability.isAvailable(in: .widget))
    }

    @Test(arguments: [ScriptHost.app, .widget])
    func allowedNotificationsPostInBothHosts(_ host: ScriptHost) {
        for status in [UNAuthorizationStatus.authorized, .provisional] {
            #expect(NotificationCapability.decision(for: status, host: host) == .post)
        }
    }

    @Test func onlyTheAppAsksForPermission() {
        guard
            case .requestPermission = NotificationCapability.decision(
                for: .notDetermined, host: .app)
        else {
            Issue.record("the app should ask for permission")
            return
        }
        guard
            case .fail(let message) = NotificationCapability.decision(
                for: .notDetermined, host: .widget)
        else {
            Issue.record("the widget must not ask for permission")
            return
        }
        #expect(message.contains("widget scripts can't ask for permission"))
    }

    @Test(arguments: [ScriptHost.app, .widget])
    func deniedNotificationsFailInBothHosts(_ host: ScriptHost) {
        guard case .fail(let message) = NotificationCapability.decision(for: .denied, host: host)
        else {
            Issue.record("denied should fail")
            return
        }
        #expect(message.contains("denied"))
    }
}

extension EmbeddedRubyTests {
    @MainActor
    @Suite(.serialized)
    struct WidgetHostBridgeTests {
        @Test func widgetClipboardCallRaisesAReadableRubyError() async throws {
            // Make the bridge register its built-in handlers now, so they can't overwrite the widget ones below on first use.
            _ = try? await RubyRuntime.shared.evaluate(
                #"RubyCuts::Native.invoke("test.none") rescue nil"#)
            ClipboardCapability.register(in: NativeBridge.shared, host: .widget)
            defer { ClipboardCapability.register(in: NativeBridge.shared, host: .app) }

            let result = await RubyRuntime.shared.run("Device::Clipboard.text")
            #expect(result.errorMessage?.contains("isn't available in widget scripts") == true)
        }
    }
}
