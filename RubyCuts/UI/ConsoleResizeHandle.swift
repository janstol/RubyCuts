import SwiftUI

/// A drag handle that resizes the console panel above it, sitting between
/// the editor and ``ConsoleOutputView`` in ``ScriptEditorView``. Its own
/// file, not a helper inside `ConsoleOutputView.swift`, because it's used by
/// `ScriptEditorView` directly rather than being part of the console's own
/// presentation.
///
/// The visible `Divider` sits inside a taller transparent hit target -- a
/// bare `Divider` is only a couple points thick, too thin to reliably grab
/// with a mouse or a finger.
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

    var body: some View {
        ZStack {
            Color.clear
            Divider()
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        #if os(macOS)
            .pointerStyle(.frameResize(position: .top))
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
