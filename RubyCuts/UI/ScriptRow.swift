import SwiftUI

/// One row in the script list: an icon, the script's name, and when it was
/// last modified. Extracted out of `ScriptListView`'s `ForEach` so the row
/// layout and the date-formatting logic below have somewhere to live on
/// their own, matching the repo's one-primary-type-per-file convention.
struct ScriptRow: View {
    let script: Script

    /// The moment the date label is relative to. Defaulted to `.now` for
    /// call sites in the app; a real value is passed in tests so the label
    /// doesn't depend on the wall clock.
    var now: Date = .now

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.name)
                if let modifiedAt = script.modifiedAt {
                    Text(Self.dateLabel(for: modifiedAt, relativeTo: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "doc.text")
        }
    }

    /// Formats `date` relative to `now`: within the last 7 days this reads as
    /// "yesterday" or "3 days ago"; older than that it reads as an absolute
    /// "Aug 20, 2026", since "47 days ago" stops being a useful at-a-glance
    /// unit. `now` is a parameter (not `Date()` inline) so the boundary is
    /// deterministic and testable rather than depending on when the test
    /// happens to run.
    ///
    /// Internal, not `private`, so `@testable import RubyCuts` can reach it
    /// directly without going through a rendered view.
    static func dateLabel(for date: Date, relativeTo now: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0
        if days < 7 {
            return date.formatted(.relative(presentation: .named))
        }
        return date.formatted(.dateTime.month().day().year())
    }
}

#Preview {
    List {
        ScriptRow(
            script: Script(
                url: URL(fileURLWithPath: "/tmp/hello.rb"),
                modifiedAt: .now.addingTimeInterval(-3600)
            )
        )
        ScriptRow(
            script: Script(
                url: URL(fileURLWithPath: "/tmp/fib.rb"),
                modifiedAt: .now.addingTimeInterval(-86400 * 30)
            )
        )
        ScriptRow(
            script: Script(url: URL(fileURLWithPath: "/tmp/no-date.rb"))
        )
    }
}
