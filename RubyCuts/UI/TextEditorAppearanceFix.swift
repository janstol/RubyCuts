#if os(macOS)
    import AppKit
    import SwiftUI

    /// Works around a macOS 26 SwiftUI bug: the `AttributedString`-backed
    /// `TextEditor` pins its own `NSScrollView` (`SwiftUI.TextEditorScrollView`)
    /// to the light `aqua` appearance, whatever the window's appearance is.
    /// Confirmed live with a debugger: every ancestor is `darkAqua`, the
    /// scroll view alone carries an explicit `aqua` override, and the
    /// `String`-backed editor has no override at all. The text still renders
    /// correctly because SwiftUI resolves its colors itself, but the Liquid
    /// Glass toolbar samples the scroll edge pocket inside that scroll view,
    /// so in Dark Mode the window title and the editor's toolbar items flip to
    /// the light variant and draw dark-on-dark.
    ///
    /// Placed behind the editor with `.background`, so it lands in the same
    /// hosting view as the editor's platform host. From there it finds any
    /// scroll view whose explicit appearance disagrees with the host's
    /// effective one and clears the override, so the scroll view inherits
    /// like every other view. Re-checked on every layout pass, since SwiftUI
    /// may re-apply the override on update. iOS has no such override, so
    /// this file is macOS-only.
    struct TextEditorAppearanceFix: NSViewRepresentable {
        func makeNSView(context: Context) -> FixView {
            FixView()
        }

        func updateNSView(_ view: FixView, context: Context) {
            view.clearStrayAppearanceOverrides()
        }

        /// The zero-size AppKit view that does the work. See the type doc
        /// comment on ``TextEditorAppearanceFix``.
        final class FixView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                clearStrayAppearanceOverrides()
            }

            override func layout() {
                super.layout()
                clearStrayAppearanceOverrides()
            }

            /// Clears the explicit `appearance` of any scroll view under the
            /// nearest SwiftUI hosting view whose override disagrees with what
            /// it would inherit. Only mismatched overrides are touched, so a
            /// scroll view SwiftUI configured correctly is left alone.
            func clearStrayAppearanceOverrides() {
                // `superview` is this representable's platform host; its
                // superview is the hosting view shared with the editor.
                guard let host = superview?.superview else { return }
                let inherited = host.effectiveAppearance.name
                for scrollView in host.descendantScrollViews()
                where scrollView.appearance != nil && scrollView.appearance?.name != inherited {
                    scrollView.appearance = nil
                }
            }
        }
    }

    extension NSView {
        /// Every `NSScrollView` in this view's subtree, depth first.
        fileprivate func descendantScrollViews() -> [NSScrollView] {
            var found: [NSScrollView] = []
            var stack = subviews
            while let view = stack.popLast() {
                if let scrollView = view as? NSScrollView {
                    found.append(scrollView)
                }
                stack.append(contentsOf: view.subviews)
            }
            return found
        }
    }
#endif
