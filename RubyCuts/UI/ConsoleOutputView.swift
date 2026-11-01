import SwiftUI

/// Displays a ``RunResult`` from ``RubyRuntime/run(_:)``: captured `STDOUT`,
/// `STDERR`, the last expression's value, and any error message. Shown in the
/// editor as a bottom panel after a Run.
///
/// Plain presentation over a value type, no view model, because the result is
/// a snapshot held in `@State` by the editor, not observable list state. The
/// header (title, metadata, status badge, Copy/Clear) is pinned above a
/// scrolling body: the body scrolls vertically so output taller than the
/// panel stays reachable, and each section additionally scrolls horizontally
/// so a long line doesn't wrap and push the error off-screen.
struct ConsoleOutputView: View {
    let result: RunResult

    /// Called when the Clear button is tapped. Defaults to a no-op so
    /// previews and tests that don't care about dismissal can ignore it.
    var onClear: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            // The vertical scroll view is what makes output taller than the
            // panel reachable at all. Without it the content below is
            // simply clipped. The per-section horizontal scroll views inside
            // stay: nested horizontal-inside-vertical scrolling is
            // supported, and it's what keeps a long line from wrapping
            // instead of scrolling sideways.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !result.stdout.isEmpty {
                        let output = Self.text(result.stdout, truncated: result.stdoutTruncated)
                        section("Output", text: Self.displayed(output))
                    }
                    if !result.stderr.isEmpty {
                        let errors = Self.text(result.stderr, truncated: result.stderrTruncated)
                        section("Errors", text: Self.displayed(errors), tint: .red)
                    }
                    // Suppressed on cancellation: "run cancelled" as a red error
                    // reads like a bug rather than the user's own action, and the
                    // badge above already says what happened.
                    if let errorMessage = result.errorMessage, !result.wasCancelled {
                        section("Error", text: errorMessage, tint: .red)
                    }
                    if !result.backtrace.isEmpty {
                        section(
                            "Backtrace", text: result.backtrace.joined(separator: "\n"),
                            tint: .red)
                    }
                    // The last expression's value is only meaningful on a clean run
                    // with a non-empty result: `puts`-only scripts end in `nil`
                    // (""), and a raised script reports via `errorMessage` above.
                    if !result.hasError && !result.result.isEmpty {
                        section("Result", text: result.result, tint: .secondary)
                    }
                }
                .padding(.bottom)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// The header, in two arms so `ViewThatFits` can fall back to stacking
    /// the title above the badge and buttons at accessibility text sizes,
    /// where ``headerRow``'s single line would otherwise collide and
    /// truncate. Each arm, and every piece inside it, is its own typed
    /// property rather than inlined here, matching this file's neighbor
    /// `ScriptEditorView`'s documented type-checker fragility with branching
    /// view expressions.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow
            headerStacked
        }
    }

    private var headerRow: some View {
        HStack {
            titleAndMetadata
            Spacer()
            statusBadge
            copyButton
            clearButton
        }
    }

    private var headerStacked: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleAndMetadata
            HStack {
                statusBadge
                Spacer()
                copyButton
                clearButton
            }
        }
    }

    private var titleAndMetadata: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Console")
                .font(.headline)
            Text(metadataLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Self.metadataAccessibilityLabel(for: result))
        }
    }

    /// The Cancelled/Failed indicator. A tinted capsule rather than bare
    /// coloured caption text, both so it's easier to see as a discrete
    /// status (not just tinted body text) and because a filled shape gives
    /// more room to satisfy contrast than text colour alone over the
    /// console background does.
    @ViewBuilder
    private var statusBadge: some View {
        if result.wasCancelled {
            badge(label: "Cancelled", systemImage: "stop.circle", tint: .orange)
        } else if result.hasError {
            badge(label: "Failed", systemImage: "exclamationmark.triangle", tint: .red)
        }
    }

    private func badge(label: String, systemImage: String, tint: Color) -> some View {
        Label(label, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.25), in: Capsule())
    }

    private var copyButton: some View {
        Button {
            ClipboardCapability.setText(Self.transcript(for: result))
        } label: {
            Image(systemName: "doc.on.doc")
                .modifier(MinimumTapTarget())
        }
        .buttonStyle(.borderless)
        .help("Copy the console output")
        .accessibilityLabel("Copy All")
    }

    private var clearButton: some View {
        Button {
            onClear()
        } label: {
            Image(systemName: "xmark.circle")
                .modifier(MinimumTapTarget())
        }
        .buttonStyle(.borderless)
        .help("Clear the console")
        .accessibilityLabel("Clear")
    }

    /// The header's second line: how long the run took and when it
    /// finished, e.g. `"0.03s · 3:41:07 PM"`.
    private var metadataLabel: String {
        let time = result.finishedAt.formatted(date: .omitted, time: .standard)
        return "\(Self.durationLabel(for: result.duration)) · \(time)"
    }

    @ViewBuilder
    private func section(_ title: String, text: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(tint ?? .secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    /// A captured stream as the console and the copied transcript show it:
    /// unchanged, or followed by a note on its own line when the run hit
    /// ``RubyRuntime/capturedOutputByteLimit``.
    static func text(_ captured: String, truncated: Bool) -> String {
        guard truncated else { return captured }
        let limit = ByteCountFormatter.string(
            fromByteCount: Int64(RubyRuntime.capturedOutputByteLimit), countStyle: .memory)
        let separator = captured.hasSuffix("\n") ? "" : "\n"
        return captured + separator + "[Cut off here: the output is larger than \(limit).]"
    }

    /// The most lines ``displayed(_:)`` keeps.
    static let maxDisplayedLines = 300

    /// The most characters ``displayed(_:)`` keeps per line.
    static let maxDisplayedLineLength = 500

    /// What a section actually draws for `text`: the last
    /// ``maxDisplayedLines`` lines, each cut at ``maxDisplayedLineLength``
    /// characters, with a note on top whenever anything was left out.
    /// Unchanged when it all fits.
    ///
    /// A section is one `Text`, and a `Text` too tall or too wide to draw
    /// (on the order of 10,000 lines, or one very long line) renders blank,
    /// even though its contents are there: Copy All copied them fine. The
    /// caps keep the drawn size well inside that, including at the
    /// iPhone's 3x scale. The tail is kept because the latest output, and
    /// the "Cut off here" note, are what matter after a long run. Copy All
    /// (``transcript(for:)``) still has everything.
    static func displayed(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let droppedLines = lines.count > maxDisplayedLines
        if droppedLines {
            lines = Array(lines.suffix(maxDisplayedLines))
        }
        var shortenedLines = false
        let shown = lines.map { line -> String in
            guard line.count > maxDisplayedLineLength else { return String(line) }
            shortenedLines = true
            return line.prefix(maxDisplayedLineLength) + "…"
        }
        guard droppedLines || shortenedLines else { return text }

        var notes: [String] = []
        if droppedLines { notes.append("Showing the last \(maxDisplayedLines) lines.") }
        if shortenedLines { notes.append("Long lines are shortened.") }
        notes.append("Copy All copies everything.")
        return "[\(notes.joined(separator: " "))]\n" + shown.joined(separator: "\n")
    }

    /// The Copy All payload: every populated section, labeled and in the
    /// same order the view renders them, skipping empty sections so the
    /// result isn't padded with blank lines. Honors the same "suppress the
    /// error section on a cancelled run" rule the view applies above.
    ///
    /// Deliberately **not** ``RubyIntents/combinedMessage(_:)``: that one
    /// is `private` to its file, and it's the *failure* contract (error
    /// message + backtrace + stderr only, no stdout, no result), the wrong
    /// payload for a copy of the whole console.
    ///
    /// Internal, not `private`, so `@testable import RubyCuts` can reach it
    /// directly without rendering a view.
    static func transcript(for result: RunResult) -> String {
        var sections: [String] = []
        if !result.stdout.isEmpty {
            sections.append("Output:\n\(text(result.stdout, truncated: result.stdoutTruncated))")
        }
        if !result.stderr.isEmpty {
            sections.append("Errors:\n\(text(result.stderr, truncated: result.stderrTruncated))")
        }
        if let errorMessage = result.errorMessage, !result.wasCancelled {
            sections.append("Error:\n\(errorMessage)")
        }
        if !result.backtrace.isEmpty {
            sections.append("Backtrace:\n\(result.backtrace.joined(separator: "\n"))")
        }
        if !result.hasError && !result.result.isEmpty {
            sections.append("Result:\n\(result.result)")
        }
        return sections.joined(separator: "\n\n")
    }

    /// Formats a run's duration for the header's metadata line:
    /// `"0.42s"` under a minute, `"1m 5s"` above.
    ///
    /// Hand-rolled rather than `Duration.UnitsFormatStyle`: exact,
    /// deterministic, and testable without locale-loose assertions. The app
    /// ships no localization today, so this doesn't regress anything.
    ///
    /// Internal, not `private`, so `@testable import RubyCuts` can reach it
    /// directly without rendering a view.
    static func durationLabel(for duration: TimeInterval) -> String {
        guard duration >= 60 else {
            return String(format: "%.2fs", duration)
        }
        let minutes = Int(duration) / 60
        let seconds = duration - Double(minutes * 60)
        return String(format: "%dm %.0fs", minutes, seconds)
    }

    /// The metadata line's VoiceOver phrasing, e.g.
    /// `"Ran in 0.03 seconds, finished at 3:41:07 PM"`. The visual label
    /// (``metadataLabel``) packs the same two facts into `"0.03s ·
    /// 3:41:07 PM"`, which reads badly aloud: the middle dot announces as
    /// "middle dot" and "s" as its own letter rather than an abbreviation
    /// for seconds.
    ///
    /// Internal, not `private`, so `@testable import RubyCuts` can reach it
    /// directly without rendering a view.
    static func metadataAccessibilityLabel(for result: RunResult) -> String {
        let time = result.finishedAt.formatted(date: .omitted, time: .standard)
        return "Ran in \(spokenDuration(for: result.duration)), finished at \(time)"
    }

    /// Spoken form of a duration for ``metadataAccessibilityLabel(for:)``:
    /// `"0.42 seconds"` under a minute, `"1 minute 5 seconds"` above,
    /// spelled out rather than abbreviated, unlike ``durationLabel(for:)``.
    private static func spokenDuration(for duration: TimeInterval) -> String {
        guard duration >= 60 else {
            return String(format: "%.2f seconds", duration)
        }
        let minutes = Int(duration) / 60
        let seconds = duration - Double(minutes * 60)
        let minuteWord = minutes == 1 ? "minute" : "minutes"
        return String(format: "%d %@ %.0f seconds", minutes, minuteWord, seconds)
    }
}

/// Grows an icon-only button to the 44pt minimum touch target on iOS and
/// iPadOS, the size the accessibility audit checks (it measures the
/// element frame, so a wider `contentShape` alone doesn't count). macOS
/// keeps the compact size its pointer doesn't need help with.
private struct MinimumTapTarget: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        #else
            content
        #endif
    }
}

#Preview {
    ConsoleOutputView(
        result: RunResult(
            stdout: "hello, world\n[1, 2, 3]",
            stderr: "warning: something",
            result: "nil",
            errorMessage: nil,
            duration: 0.03,
            finishedAt: .now
        )
    )
    .frame(maxWidth: 400, maxHeight: 250)
}

#Preview {
    ConsoleOutputView(
        result: RunResult(
            stdout: "printed before crash",
            stderr: "",
            result: "",
            errorMessage: "undefined method 'foo' for nil (NoMethodError)",
            backtrace: [
                "rubycuts:3:in 'foo'",
                "rubycuts:1:in '<main>'",
            ],
            duration: 0.12,
            finishedAt: .now
        )
    )
    .frame(maxWidth: 400, maxHeight: 200)
}

#Preview {
    ConsoleOutputView(
        result: RunResult(
            stdout: "before\n",
            stderr: "",
            result: "",
            errorMessage: "run cancelled",
            wasCancelled: true,
            duration: 5.2,
            finishedAt: .now
        )
    )
    .frame(maxWidth: 400, maxHeight: 200)
}

#Preview("Failed, Accessibility Text Size") {
    // Checks the header's `ViewThatFits` fallback: at this size the badge
    // and buttons no longer fit alongside the title on one line.
    ConsoleOutputView(
        result: RunResult(
            stdout: "printed before crash",
            stderr: "",
            result: "",
            errorMessage: "undefined method 'foo' for nil (NoMethodError)",
            duration: 0.12,
            finishedAt: .now
        )
    )
    .frame(maxWidth: 400, maxHeight: 300)
    .dynamicTypeSize(.accessibility3)
}
