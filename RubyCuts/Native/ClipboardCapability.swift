import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// The `Device::Clipboard` capability: read and write the system pasteboard
/// from Ruby. `UIPasteboard.general` on iOS, `NSPasteboard.general` on
/// macOS: both synchronous and needing no entitlement.
///
/// Reading on iOS shows the system paste banner. That's Apple's privacy gate
/// on pasteboard reads, not something to suppress or work around.
enum ClipboardCapability {
    /// Registers the get/set handlers on `bridge`. In the widget extension both raise ``widgetUnavailableMessage`` instead (see ``isAvailable(in:)``).
    @MainActor
    static func register(in bridge: NativeBridge, host: ScriptHost = .current) {
        bridge.register("device.clipboard.get") { _ in
            try requireAvailable(in: host)
            return currentText()
        }
        bridge.register("device.clipboard.set") { args in
            try requireAvailable(in: host)
            guard let text = args.first else {
                throw NativeBridgeError(message: "device.clipboard.set requires one argument")
            }
            setText(text)
            return nil
        }
    }

    /// Whether scripts in `host` may use the clipboard. Not in a widget: it runs in the background on every refresh, so it would read the clipboard (or try to show the paste prompt) and overwrite it without anyone looking.
    nonisolated static func isAvailable(in host: ScriptHost) -> Bool {
        host == .app
    }

    /// The error a widget script gets from `Device::Clipboard`.
    nonisolated static let widgetUnavailableMessage =
        "Device::Clipboard isn't available in widget scripts. Run the script in the app or from Shortcuts to use the clipboard."

    private static func requireAvailable(in host: ScriptHost) throws {
        guard isAvailable(in: host) else {
            throw NativeBridgeError(message: widgetUnavailableMessage)
        }
    }

    /// The Ruby surface this capability adds: `Device::Clipboard.text` / `.text=`.
    /// `nonisolated` so `NativeBridge.preludeSource` can read it from the VM
    /// thread with no main-actor hop: it's a plain `String` constant.
    nonisolated static let preludeSource = """
        module Device
          module Clipboard
            def self.text
              RubyCuts::Native.invoke("device.clipboard.get")
            end

            def self.text=(value)
              RubyCuts::Native.invoke("device.clipboard.set", value)
              value
            end
          end
        end
        """

    /// Reads the current pasteboard text, or `nil` if the pasteboard holds no
    /// string content. Not `private`: ``NativeBridgeTests`` reads and
    /// restores the developer's real clipboard around its round-trip test
    /// through this, rather than through Ruby, to avoid nil/empty-string
    /// ambiguity.
    static func currentText() -> String? {
        #if canImport(UIKit)
            return UIPasteboard.general.string
        #elseif canImport(AppKit)
            return NSPasteboard.general.string(forType: .string)
        #else
            return nil
        #endif
    }

    /// Sets the pasteboard's text content, or clears it entirely when `text`
    /// is `nil`. The `nil` case only matters to test restoration: the
    /// registered `device.clipboard.set` handler always passes a real string.
    static func setText(_ text: String?) {
        guard let text else {
            clearText()
            return
        }
        #if canImport(UIKit)
            UIPasteboard.general.string = text
        #elseif canImport(AppKit)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        #endif
    }

    private static func clearText() {
        #if canImport(UIKit)
            UIPasteboard.general.items = []
        #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
        #endif
    }
}
