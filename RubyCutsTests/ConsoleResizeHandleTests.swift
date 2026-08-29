import Foundation
import Testing

@testable import RubyCuts

// Tests for `ConsoleResizeHandle.adjusted(_:by:in:)`, the step-and-clamp
// logic behind its VoiceOver adjustable action. No view rendered, no
// accessibility action driven -- just the arithmetic.
struct ConsoleResizeHandleTests {
    private let bounds: ClosedRange<Double> = 100...500

    @Test func incrementingStepsUpByTheDelta() {
        let result = ConsoleResizeHandle.adjusted(220, by: 20, in: bounds)

        #expect(result == 240)
    }

    @Test func decrementingStepsDownByTheDelta() {
        let result = ConsoleResizeHandle.adjusted(220, by: -20, in: bounds)

        #expect(result == 200)
    }

    @Test func incrementingPastTheUpperBoundClampsToIt() {
        let result = ConsoleResizeHandle.adjusted(490, by: 20, in: bounds)

        #expect(result == 500)
    }

    @Test func decrementingPastTheLowerBoundClampsToIt() {
        let result = ConsoleResizeHandle.adjusted(110, by: -20, in: bounds)

        #expect(result == 100)
    }
}
