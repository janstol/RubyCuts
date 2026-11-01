import Foundation

/// One page of the in-app documentation: a guide (how to wire a script into a
/// Shortcut, how input reaches it...) or an API module (`Device::Clipboard`).
/// The index shows ``title`` and ``summary``; the detail page shows the rest.
///
/// Pure data with no actor-coupled state, so it opts out of the app target's
/// MainActor-by-default isolation, like ``RunInput``: the test target reads
/// the catalog without a main-actor hop.
nonisolated struct DocTopic: Identifiable, Hashable, Sendable {
    /// Which index section a topic is listed under.
    nonisolated enum Kind: Hashable, Sendable {
        /// Task-oriented prose: running from Shortcuts, input, output...
        case guide
        /// A Ruby module RubyCuts adds, documented member by member.
        case api
    }

    /// A stable slug, e.g. `"device-clipboard"`. Unique across the catalog.
    let id: String

    /// The index section this topic belongs to.
    let kind: Kind

    /// The row title and the detail page's navigation title.
    let title: String

    /// One line shown under the title in the index, and matched by search.
    let summary: String

    /// The paragraph(s) at the top of the detail page.
    let overview: String

    /// Methods, globals or Shortcut actions the topic covers. Empty when the
    /// overview and examples say everything.
    var members: [DocMember] = []

    /// Code samples shown with a Copy button. Every one is compiled, and most
    /// are run, by `DocExampleTests`.
    var examples: [DocExample] = []

    /// Caveats shown at the bottom of the page, e.g. the iOS paste banner.
    var notes: [String] = []
}

/// One documented member of a topic: a monospaced signature and what it does.
nonisolated struct DocMember: Hashable, Sendable {
    /// The code-shaped name, e.g. `Device::Clipboard.text`.
    let signature: String

    /// A sentence or two on what the member does.
    let explanation: String
}

/// A copyable code sample, and how the test suite checks it still works.
nonisolated struct DocExample: Hashable, Sendable {
    /// A short heading above the code.
    let title: String

    /// The Ruby source shown on the page and copied by the Copy button.
    let code: String

    /// How `DocExampleTests` checks ``code``.
    let verification: Verification

    /// How an example is checked by the tests, so the docs can't go stale
    /// without a test failing.
    nonisolated enum Verification: Hashable, Sendable {
        /// Run in the embedded VM with the given Shortcut input. With
        /// `expectedError` set the run must raise that message; otherwise it
        /// must finish cleanly with nothing on STDERR, and print
        /// `expectedStdout` when that is set.
        case runs(
            argv: [String] = [],
            stdin: String = "",
            env: [String: String] = [:],
            expectedStdout: String? = nil,
            expectedError: String? = nil
        )

        /// Only syntax-checked: running it would touch the clipboard, post a
        /// notification or hit the network.
        case compilesOnly
    }
}
