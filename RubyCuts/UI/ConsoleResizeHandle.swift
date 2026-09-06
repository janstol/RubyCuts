import SwiftUI

/// A drag handle that resizes the console panel above it, sitting between
/// the editor and ``ConsoleOutputView`` in ``ScriptEditorView``. Its own
/// file, not a helper inside `ConsoleOutputView.swift`, because it's used by
/// `ScriptEditorView` directly rather than being part of the console's own
/// presentation.
///
/// The visible `Divider` sits inside a taller transparent hit target. A
/// bare `Divider` is only a couple points thick, too thin to reliably grab
/// with a mouse or a finger. On iOS/iPadOS the hit target grows further
/// still, past the 8pt laid-out height, since a finger needs closer to the
/// 44pt platform minimum than a mouse does; the *laid-out* height stays 8pt
/// on every platform so ``ScriptEditorView/resizeHandleHeight`` (a separate
/// constant feeding the console's clamp) doesn't drift out of sync with it.
///
/// Also exposes itself as a VoiceOver adjustable element: dragging is
/// unreachable without a pointer, so ``adjusted(_:by:in:)`` gives VoiceOver
/// (and any other adjustable-action client) an up/down-arrow path to the
/// same resize the drag gesture performs.
struct ConsoleResizeHandle: View {
    /// The console panel's height, resized in place as the user drags.
    @Binding var height: Double

    /// The clamp the dragged height is kept within, so a drag can't collapse
    /// the console to nothing or push the editor off-screen. The caller
    /// computes this against its own available space.
    let bounds: ClosedRange<Double>

    /// `height`'s value when the current drag started, so each drag delta is
    /// applied relative to a fixed baseline rather than the
    /// continuously-updating `height` itself.
    @State private var heightAtDragStart: Double?

    /// The step ``adjusted(_:by:in:)`` moves ``height`` by on each VoiceOver
    /// increment/decrement.
    private static let adjustmentStep: Double = 20

    var body: some View {
        ZStack {
            Color.clear
            Divider()
        }
        .frame(height: 8)
        #if os(macOS)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .top))
        #else
            // Extends the hit-testing region 18pt above and below the 8pt
            // visual line, 44pt total, the platform's minimum touch
            // target, without changing the laid-out height itself.
            .contentShape(Rectangle().inset(by: -18))
        #endif
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = heightAtDragStart ?? height
                    heightAtDragStart = start
                    // Dragging up (negative translation.height) grows the
                    // console, since the handle sits above a panel anchored
                    // to the bottom of the window.
                    let proposed = start - value.translation.height
                    height = min(max(proposed, bounds.lowerBound), bounds.upperBound)
                }
                .onEnded { _ in
                    heightAtDragStart = nil
                }
        )
        .onTapGesture(count: 2) {
            height = min(max(220, bounds.lowerBound), bounds.upperBound)
        }
        .accessibilityElement()
        .accessibilityLabel("Console Height")
        .accessibilityValue("\(Int(height)) points")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                height = Self.adjusted(height, by: Self.adjustmentStep, in: bounds)
            case .decrement:
                height = Self.adjusted(height, by: -Self.adjustmentStep, in: bounds)
            @unknown default:
                break
            }
        }
    }

    /// Steps `current` by `delta` (positive to grow, negative to shrink),
    /// clamped into `bounds`, the same clamp the drag gesture applies, so
    /// an adjustable action can never push the height further out of range
    /// than a drag could. Backs the VoiceOver increment/decrement action in
    /// ``body``.
    ///
    /// Internal, not `private`, so `@testable import RubyCuts` can reach it
    /// directly without driving an accessibility action through a rendered
    /// view.
    static func adjusted(_ current: Double, by delta: Double, in bounds: ClosedRange<Double>)
        -> Double
    {
        min(max(current + delta, bounds.lowerBound), bounds.upperBound)
    }
}

#Preview {
    VStack(spacing: 0) {
        Color.blue.opacity(0.2)
        ConsoleResizeHandle(height: .constant(220), bounds: 100...500)
        Color.green.opacity(0.2)
    }
    .frame(width: 400, height: 400)
}
