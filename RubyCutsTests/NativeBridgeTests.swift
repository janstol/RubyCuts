import Foundation
@testable import RubyCuts
import Testing
import UserNotifications

// Same single-threaded VM contract as ``RubyRuntimeTests``: `.serialized`
// because every test drives the one non-thread-safe embedded CRuby VM through
// `RubyRuntime.shared`. `NativeBridge.shared` is likewise a singleton, so
// each test registers its own uniquely-named capability rather than reusing
// one across tests. Nested under ``EmbeddedRubyTests`` so `.serialized`
// covers `RubyRuntimeTests` and `GemArchiveTests` too; see that type's
// doc comment.
extension EmbeddedRubyTests {
    @MainActor
    @Suite(.serialized)
    struct NativeBridgeTests {

        // MARK: - Mechanism: registry round-trip through RubyCuts::Native.invoke

        @Test func roundTripsThroughARegisteredHandler() async throws {
            // Boots the VM (RubyCuts::Native/NativeError are defined at boot) and
            // proves a handler registered directly on the shared registry is
            // reachable from Ruby, the mechanism, independent of any built-in
            // capability.
            NativeBridge.shared.register("test.echo") { args in args.first }
            let result = try await RubyRuntime.shared.evaluate(
                #"RubyCuts::Native.invoke("test.echo", "hello")"#
            )
            #expect(result == "hello")
        }

        @Test func handlerResultRoundTripsQuotesNewlinesAndNonASCII() async throws {
            // The JSON envelope's whole reason for existing: a result string with
            // quotes, a newline, and non-ASCII must survive Swift -> JSON ->
            // Ruby unchanged.
            let tricky = "quo\"te\nnew\u{00e9}line \u{1F600}"
            NativeBridge.shared.register("test.tricky") { _ in tricky }
            let result = try await RubyRuntime.shared.evaluate(
                #"RubyCuts::Native.invoke("test.tricky")"#)
            #expect(result == tricky)
        }

        @Test func argsRoundTripQuotesNewlinesAndNonASCII() async throws {
            // Same guarantee in the other direction: an argument Ruby sends with
            // quotes, a newline, and non-ASCII must reach the Swift handler
            // unchanged. Transported into the Ruby source via base64 (like
            // RunInput does) so the test itself doesn't need to hand-escape the
            // tricky string into a Ruby literal.
            NativeBridge.shared.register("test.echo") { args in args.first }
            let tricky = "quo\"te\nnew\u{00e9}line \u{1F600}"
            let encoded = Data(tricky.utf8).base64EncodedString()
            let code = """
                require 'base64'
                RubyCuts::Native.invoke("test.echo", Base64.decode64("\(encoded)"))
                """
            let result = try await RubyRuntime.shared.evaluate(code)
            #expect(result == tricky)
        }

        @Test func nilReturnSurvivesAsRubyNilNotEmptyString() async throws {
            NativeBridge.shared.register("test.nil") { _ in nil }
            let result = try await RubyRuntime.shared.evaluate(
                #"RubyCuts::Native.invoke("test.nil").nil? ? "was-nil" : "was-not-nil""#
            )
            #expect(result == "was-nil")
        }

        @Test func throwingHandlerRaisesANativeErrorRescuableInRuby() async throws {
            NativeBridge.shared.register("test.boom") { _ in
                throw NativeBridgeError(message: "boom from swift")
            }
            let result = try await RubyRuntime.shared.evaluate(
                """
                begin
                  RubyCuts::Native.invoke("test.boom")
                  "no-error"
                rescue RubyCuts::NativeError => e
                  e.message
                end
                """
            )
            #expect(result == "boom from swift")
        }

        @Test func unknownCapabilityRaisesANativeErrorRatherThanCrashing() async throws {
            let result = try await RubyRuntime.shared.evaluate(
                """
                begin
                  RubyCuts::Native.invoke("test.does-not-exist")
                  "no-error"
                rescue RubyCuts::NativeError
                  "rescued"
                end
                """
            )
            #expect(result == "rescued")
        }

        @Test func nonStringArgumentIsRejectedWithANativeError() async throws {
            NativeBridge.shared.register("test.echo") { args in args.first }
            let result = try await RubyRuntime.shared.evaluate(
                """
                begin
                  RubyCuts::Native.invoke("test.echo", 42)
                  "no-error"
                rescue RubyCuts::NativeError
                  "rescued"
                end
                """
            )
            #expect(result == "rescued")
        }

        // MARK: - Device::Clipboard

        @Test func clipboardRoundTripsAndRestoresPriorContents() async throws {
            // Save/restore goes through ClipboardCapability's own getter/setter,
            // not through Ruby, so a prior `nil` (empty pasteboard) round-trips
            // correctly instead of being conflated with an empty string.
            let previous = ClipboardCapability.currentText()
            defer { ClipboardCapability.setText(previous) }

            _ = try await RubyRuntime.shared.evaluate(
                #"Device::Clipboard.text = "from-native-bridge-test""#)
            let readBack = try await RubyRuntime.shared.evaluate("Device::Clipboard.text")
            #expect(readBack == "from-native-bridge-test")
        }

        // MARK: - Device::Notification

        @Test func notifyRaisesWhenCachedAuthorizationIsDenied() async throws {
            // Drives the guard purely off the cached status: no real
            // authorization prompt or delivery, which needs a device.
            let previous = NotificationCapability.cachedAuthorizationStatus
            defer { NotificationCapability.cachedAuthorizationStatus = previous }
            NotificationCapability.cachedAuthorizationStatus = .denied

            let result = try await RubyRuntime.shared.evaluate(
                """
                begin
                  Device::Notification.notify("Title", "Body")
                  "no-error"
                rescue RubyCuts::NativeError
                  "rescued"
                end
                """
            )
            #expect(result == "rescued")
        }

    }
}
