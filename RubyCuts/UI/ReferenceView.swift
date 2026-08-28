import SwiftUI

/// The in-app answer to "what is RubyCuts for" and "how do I wire this into a
/// Shortcut" -- PRD 3.6's in-app documentation of the ARGV/STDIN/ENV contract
/// and the native bridge, and PRD 6's success metric that a new user reaches
/// a working Shortcut without leaving the app.
///
/// Content-only, matching ``GemListView``: a `List` of `Section`s and a
/// `.navigationTitle`, no navigation chrome or sizing frame of its own. The
/// host supplies those -- a sheet from ``ScriptListView`` on iOS/iPadOS, a
/// dedicated `Window` scene reached from the Help menu on macOS.
struct ReferenceView: View {
    var body: some View {
        List {
            runningFromShortcutsSection
            inputSection
            outputSection
            clipboardSection
            notificationSection
            rubyEnvironmentSection
        }
        .navigationTitle("Reference")
    }

    private var runningFromShortcutsSection: some View {
        Section("Running from Shortcuts") {
            ReferenceRow(
                code: "Run Inline Ruby",
                explanation: "Runs a code string typed straight into the Shortcut action."
            )
            ReferenceRow(
                code: "Run Ruby Script",
                explanation: "Runs a script picked from your saved library by name."
            )
            Text("Both actions return the script's STDOUT to the next action in the Shortcut.")
                .foregroundStyle(.secondary)
        }
    }

    private var inputSection: some View {
        Section("Input") {
            ReferenceRow(
                code: "ARGV[0]",
                explanation: "Reads the Shortcuts \"ARGV\" field: a list, one element per entry."
            )
            ReferenceRow(
                code: "$stdin.read",
                explanation:
                    "Reads the Shortcuts \"STDIN\" field: text piped in from a previous action."
            )
            ReferenceRow(
                code: "ENV[\"KEY\"]",
                explanation:
                    "Reads one line of the Shortcuts \"Environment\" field, formatted KEY=value -- one pair per line."
            )
        }
    }

    private var outputSection: some View {
        Section("Output") {
            ReferenceRow(
                code: "puts \"...\"",
                explanation: "Anything written to STDOUT is returned to the next Shortcut action."
            )
            ReferenceRow(
                code: "puts JSON.generate(hash)",
                explanation:
                    "Prints JSON that Shortcuts' \"Get Dictionary from Input\" action can parse."
            )
            Text(
                "A raise, or anything written to STDERR, fails the Shortcut and shows the message and backtrace."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var clipboardSection: some View {
        Section("Device::Clipboard") {
            ReferenceRow(
                code: "Device::Clipboard.text",
                explanation: "Reads the system pasteboard as a string, or nil if it holds none."
            )
            ReferenceRow(
                code: "Device::Clipboard.text = \"...\"",
                explanation: "Sets the system pasteboard's text."
            )
            Text(
                "On iOS, reading the pasteboard shows the system paste banner -- that's Apple's privacy gate, not something RubyCuts can suppress."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var notificationSection: some View {
        Section("Device::Notification") {
            ReferenceRow(
                code: "Device::Notification.notify(title, body)",
                explanation: "Posts a local notification."
            )
            Text(
                "The first call after installing the app raises while the system shows its permission prompt in the background. Allow it, then call notify again -- the second call succeeds."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var rubyEnvironmentSection: some View {
        Section("Ruby Environment") {
            ReferenceRow(
                code: "RUBY_VERSION",
                explanation: "CRuby 3.4.9, embedded directly -- no system Ruby involved."
            )
            Text("Stdlib is bundled, including json, csv, net/http, and openssl.")
                .foregroundStyle(.secondary)
            Text("sqlite3 is bundled as a C extension.")
                .foregroundStyle(.secondary)
            Text(
                "Pure-Ruby gems can be installed from Settings. Gems with a C extension can't be loaded -- the App Store's W^X rules block dlopen-ing anything downloaded at runtime."
            )
            .foregroundStyle(.secondary)
        }
    }
}

/// A single reference entry: a monospaced code line above its prose
/// explanation.
private struct ReferenceRow: View {
    let code: String
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(code)
                .font(.system(.body, design: .monospaced))
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        ReferenceView()
    }
}
