import Foundation
@testable import RubyCuts
import Testing

// Tests for `ScriptRow`'s date-label formatting. `now` is a fixed reference
// point rather than `Date()`, so these don't depend on when the test happens
// to run.
@MainActor
struct ScriptRowTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func aRecentDateFormatsRelative() {
        let yesterday = now.addingTimeInterval(-86400)

        let label = ScriptRow.dateLabel(for: yesterday, relativeTo: now)

        // `.relative(presentation: .named)` renders this as "yesterday" in
        // the current locale/language; check it's not the absolute form
        // rather than pinning the exact localized string.
        #expect(!label.contains("2023"))
    }

    @Test func aDateOlderThanAWeekFormatsAbsolute() {
        let monthAgo = now.addingTimeInterval(-86400 * 30)

        let label = ScriptRow.dateLabel(for: monthAgo, relativeTo: now)

        // The absolute form includes the year; the relative form never does.
        #expect(label.contains("2023"))
    }

    // MARK: - accessibilityLabel(for:relativeTo:)

    @Test func accessibilityLabelCombinesTheNameAndTheDate() {
        let script = Script(
            url: URL(fileURLWithPath: "/tmp/hello.rb"),
            modifiedAt: now.addingTimeInterval(-86400)
        )

        let label = ScriptRow.accessibilityLabel(for: script, relativeTo: now)

        #expect(label.contains("hello"))
        #expect(label.contains("modified"))
        // Not the bare date fragment: the date must read as tied to the
        // script, not as a detached trailing word.
        #expect(!label.hasPrefix("modified"))
    }

    @Test func accessibilityLabelFallsBackToJustTheNameWithNoModifiedDate() {
        let script = Script(url: URL(fileURLWithPath: "/tmp/no-date.rb"))

        let label = ScriptRow.accessibilityLabel(for: script, relativeTo: now)

        #expect(label == "no-date")
    }
}
