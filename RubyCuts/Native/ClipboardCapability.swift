import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// The `Device::Clipboard` capability: read and write the system pasteboard
/// from Ruby. `UIPasteboard.general` on iOS, `NSPasteboard.general` on
/// macOS -- both synchronous and needing no entitlement.
///
/// Reading on iOS shows the system paste banner. That's Apple's privacy gate
/// on pasteboard reads, not something to suppress or work around.
enum ClipboardCapability {
    /// Registers the get/set handlers on `bridge`.
    @MainActor
    static func register(in bridge: NativeBridge) {
        bridge.register("device.clipboard.get") { _ in currentText() }
        bridge.register("device.clipboard.set") { args in
            guard let text = args.first else {
                throw NativeBridgeError(message: "device.clipboard.set requires one argument")
            }
            setText(text)
            return nil
        }
    }

    /// The Ruby surface this capability adds: `Device::Clipboard.text` / `.text=`.
    static let preludeSource = """
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
    /// string content. Not `private` -- ``NativeBridgeTests`` reads and
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
    /// is `nil`. The `nil` case only matters to test restoration -- the
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
