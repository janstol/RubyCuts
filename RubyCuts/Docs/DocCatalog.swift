import Foundation

/// Every page of the RubyCuts tab of the in-app documentation, in index order.
///
/// Static data, `nonisolated` like ``DocTopic``. Examples marked
/// ``DocExample/Verification/runs(argv:stdin:env:expectedStdout:expectedError:)``
/// are executed by `DocExampleTests`, so an expected output here is a claim the
/// test suite checks.
nonisolated enum DocCatalog {
    /// All topics: guides first, then API modules.
    static let topics: [DocTopic] = guides + api

    /// Topics listed under "Guides".
    static var guides: [DocTopic] {
        [runningFromShortcuts, input, outputAndErrors, gems, rubyEnvironment]
    }

    /// Topics listed under "API".
    static var api: [DocTopic] { [clipboard, notification] }

    /// Every example in the catalog, across all topics.
    static var allExamples: [DocExample] { topics.flatMap(\.examples) }

    /// The examples `DocExampleTests` executes, rather than only compiles.
    static var runnableExamples: [DocExample] {
        allExamples.filter {
            if case .runs = $0.verification { return true }
            return false
        }
    }

    // MARK: - Guides

    static let runningFromShortcuts = DocTopic(
        id: "running-from-shortcuts",
        kind: .guide,
        title: "Running from Shortcuts",
        summary: "The two Shortcuts actions and what they return.",
        overview: """
            RubyCuts adds two actions to the Shortcuts app. Both run Ruby in the app's embedded interpreter and pass whatever the script prints to STDOUT on to the next action in the Shortcut.

            Each action also has optional ARGV, STDIN and Environment fields for passing data into the script. See Input.
            """,
        members: [
            DocMember(
                signature: "Run Inline Ruby",
                explanation: "Runs a code string typed straight into the Shortcut action."),
            DocMember(
                signature: "Run Ruby Script",
                explanation: "Runs a script picked from your saved library."),
        ],
        examples: [
            DocExample(
                title: "Hello from a Shortcut",
                code: #"puts "Hello from RubyCuts""#,
                verification: .runs(expectedStdout: "Hello from RubyCuts\n"))
        ],
        notes: [
            "Only STDOUT is returned. The value of the script's last expression is not, so print what you want the next action to receive.",
            "If a script picked in Run Ruby Script is later renamed or deleted, the action fails with \"script not found\". Pick the script again in the Shortcut.",
        ]
    )

    static let input = DocTopic(
        id: "input",
        kind: .guide,
        title: "Input: ARGV, STDIN, ENV",
        summary: "Pass Shortcut data into a script.",
        overview: """
            The Shortcuts actions have three optional input fields. Each one shows up in Ruby the way it would for a command-line script, so the same code works in RubyCuts and in a terminal.
            """,
        members: [
            DocMember(
                signature: "ARGV",
                explanation:
                    "The \"ARGV\" field: a list, one element per entry. ARGV[0] is the first entry."
            ),
            DocMember(
                signature: "$stdin.read",
                explanation: "The \"STDIN\" field: text piped in from a previous action."),
            DocMember(
                signature: "ENV[\"KEY\"]",
                explanation: "The \"Environment\" field: one KEY=value pair per line."),
        ],
        examples: [
            DocExample(
                title: "Greet the first argument",
                code: #"""
                    name = ARGV.first || "world"
                    puts "Hello, #{name}!"
                    """#,
                verification: .runs(argv: ["Ruby"], expectedStdout: "Hello, Ruby!\n")),
            DocExample(
                title: "Uppercase piped-in text",
                code: #"""
                    text = $stdin.read
                    puts text.upcase
                    """#,
                verification: .runs(stdin: "hello", expectedStdout: "HELLO\n")),
            DocExample(
                title: "Count lines",
                code: #"""
                    lines = $stdin.read.lines(chomp: true)
                    puts "#{lines.size} lines"
                    """#,
                verification: .runs(stdin: "one\ntwo\nthree", expectedStdout: "3 lines\n")),
            DocExample(
                title: "Read a setting with a fallback",
                code: #"puts ENV.fetch("GREETING", "Hi")"#,
                verification: .runs(env: ["GREETING": "Howdy"], expectedStdout: "Howdy\n")),
        ],
        notes: [
            "In the Environment field, a line is split at its first =, so a value may itself contain =. Blank lines and lines without = are skipped.",
            "The in-app Run button passes no input: ARGV is empty, STDIN is empty and ENV has no Shortcut values. Give your script a fallback, as the examples do, to try it in the editor.",
        ]
    )

    static let outputAndErrors = DocTopic(
        id: "output-and-errors",
        kind: .guide,
        title: "Output & Errors",
        summary: "Return text or JSON, and fail a Shortcut on purpose.",
        overview: """
            Everything a script writes to STDOUT becomes the action's result. Print JSON to hand Shortcuts a dictionary: its "Get Dictionary from Input" action parses it.

            A script that raises, or writes anything to STDERR, fails the action. The Shortcut stops and shows the error message and backtrace.
            """,
        members: [
            DocMember(
                signature: "puts \"...\"",
                explanation: "Writes a line to STDOUT, which is returned to the next action."),
            DocMember(
                signature: "puts JSON.generate(hash)",
                explanation: "Prints JSON that \"Get Dictionary from Input\" can parse."),
            DocMember(
                signature: "raise \"message\"",
                explanation: "Fails the action with this message."),
            DocMember(
                signature: "warn \"message\"",
                explanation: "Writes to STDERR, which also fails the action."),
        ],
        examples: [
            DocExample(
                title: "Return a dictionary",
                code: #"""
                    require 'json'
                    puts JSON.generate({ "name" => "RubyCuts", "count" => 3 })
                    """#,
                verification: .runs(expectedStdout: "{\"name\":\"RubyCuts\",\"count\":3}\n")),
            DocExample(
                title: "Stop the Shortcut when input is missing",
                code: #"""
                    raise "No input given" if ARGV.empty?
                    puts ARGV.join(", ")
                    """#,
                verification: .runs(expectedError: "No input given")),
        ],
        notes: [
            "STDOUT and STDERR are each capped at 1 MB. Output past the cap is dropped, and the action fails rather than return a partial result."
        ]
    )

    static let gems = DocTopic(
        id: "gems",
        kind: .guide,
        title: "Gems",
        summary: "Which gems a script can require.",
        overview: gemsOverview,
        examples: [
            DocExample(
                title: "An in-memory SQLite database",
                code: #"""
                    require 'sqlite3'
                    db = SQLite3::Database.new(":memory:")
                    db.execute("CREATE TABLE notes (body TEXT)")
                    db.execute("INSERT INTO notes VALUES (?)", ["hello"])
                    puts db.execute("SELECT body FROM notes").flatten.first
                    """#,
                verification: .runs(expectedStdout: "hello\n"))
        ]
    )

    private static var gemsOverview: String {
        let bundled =
            "sqlite3 is bundled with the app as a C extension, so require 'sqlite3' works without installing anything."
        #if RUBYCUTS_GEMS
            return bundled + "\n\n"
                + "Pure-Ruby gems can be installed from Settings, then loaded with require. Gems with a C extension can't be loaded: the App Store's rules block loading native code downloaded at runtime."
        #else
            return bundled
        #endif
    }

    static let rubyEnvironment = DocTopic(
        id: "ruby-environment",
        kind: .guide,
        title: "Ruby Environment",
        summary: "CRuby 3.4.9 with the standard library bundled.",
        overview: """
            RubyCuts embeds CRuby 3.4.9 directly. No system Ruby is involved, and nothing needs to be installed.

            The standard library is bundled, including json, csv, net/http, uri, date, yaml and openssl. HTTPS requests work out of the box.
            """,
        members: [
            DocMember(signature: "RUBY_VERSION", explanation: "The embedded Ruby version.")
        ],
        examples: [
            DocExample(
                title: "Print the Ruby version",
                code: "puts RUBY_VERSION",
                verification: .runs(expectedStdout: "3.4.9\n")),
            DocExample(
                title: "Fetch a web page",
                code: #"""
                    require 'net/http'
                    puts Net::HTTP.get(URI("https://example.com"))
                    """#,
                verification: .compilesOnly),
        ],
        notes: ["The Ruby tab links to the API docs for the core classes and bundled libraries."]
    )

    // MARK: - API

    static let clipboard = DocTopic(
        id: "device-clipboard",
        kind: .api,
        title: "Device::Clipboard",
        summary: "Read and write the system clipboard.",
        overview:
            "Reads and writes plain text on the system pasteboard. Available in every script without a require.",
        members: [
            DocMember(
                signature: "Device::Clipboard.text",
                explanation: "Returns the clipboard's text, or nil if it holds none."),
            DocMember(
                signature: "Device::Clipboard.text = \"...\"",
                explanation: "Replaces the clipboard's contents with the string."),
        ],
        examples: [
            DocExample(
                title: "Uppercase the clipboard",
                code: #"""
                    text = Device::Clipboard.text.to_s
                    Device::Clipboard.text = text.upcase
                    """#,
                verification: .compilesOnly)
        ],
        notes: [
            "On iOS, reading the clipboard shows the system paste banner. That's Apple's privacy gate, not something RubyCuts can suppress."
        ]
    )

    static let notification = DocTopic(
        id: "device-notification",
        kind: .api,
        title: "Device::Notification",
        summary: "Post a local notification.",
        overview:
            "Posts a notification from a script, for example when a long-running Shortcut finishes. Available in every script without a require.",
        members: [
            DocMember(
                signature: "Device::Notification.notify(title, body)",
                explanation: "Posts a local notification with this title and body.")
        ],
        examples: [
            DocExample(
                title: "Report when done",
                code: ##"Device::Notification.notify("Backup done", "#{ARGV.size} files copied")"##,
                verification: .compilesOnly)
        ],
        notes: [
            "The first call after installing the app raises while the system shows its permission prompt. Allow notifications, then call notify again: the second call succeeds."
        ]
    )
}
