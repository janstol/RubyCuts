import Foundation
import Testing

@testable import RubyCuts

// Tests for `ScriptRow`'s date-label formatting. `now` is a fixed reference
// point rather than `Date()`, so these don't depend on when the test happens
// to run.
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
}
