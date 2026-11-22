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
        [runningFromShortcuts, input, outputAndErrors, widgets, gems, rubyEnvironment]
    }

    /// Topics listed under "API".
    static var api: [DocTopic] { [clipboard, notification, widgetUI] }

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

    static let widgets = DocTopic(
        id: "widgets",
        kind: .guide,
        title: "Widgets",
        summary: "Show a script's output on the Home Screen or desktop.",
        overview: """
            A script can draw a widget. Build the layout with WidgetUI and end with present, then run the script in the app: the console shows a preview at small and medium size.

            To put it on the Home Screen or the Mac desktop, add the RubyCuts widget, edit it and choose the script. The widget runs the script itself, about every 15 minutes or as often as the system allows, so it can fetch fresh data each time. Running a widget script in the app refreshes the widget straight away, and tapping the widget opens its script.

            A script can ask for another refresh interval with present(refresh_after: seconds), and adapt to the widget's size with WidgetUI.family. Pick Small, Medium or Large above the console preview to see each size; a script that reads WidgetUI.family runs again for the new size.
            """,
        examples: [
            DocExample(
                title: "The smallest widget",
                code: #"""
                    WidgetUI.new do
                      Text("Hello from Ruby").font(:headline).padding
                    end.present
                    """#,
                verification: .runs()),
            DocExample(
                title: "Fresh data on every refresh",
                code: #"""
                    require 'net/http'

                    quote = begin
                      Net::HTTP.start("api.github.com", 443, use_ssl: true, open_timeout: 5, read_timeout: 5) do |http|
                        http.get("/zen").body
                      end
                    rescue StandardError
                      "Offline"
                    end

                    WidgetUI.new do
                      VStack(alignment: :leading) {
                        Text(Time.now.strftime("%H:%M")).font(:caption)
                        Spacer()
                        Text(quote).font(:headline)
                      }
                      .padding
                      .frame(width: :infinity, height: :infinity)
                    end.present
                    """#,
                verification: .compilesOnly),
        ],
        notes: [
            "A widget script is stopped after 15 seconds. Stopping can't interrupt a network read that's already waiting, so give Net::HTTP short open_timeout and read_timeout values.",
            "Widgets get little memory. Keep downloads small and avoid parsing very large JSON responses.",
            "The widget runs the saved version of the script. If the script fails, the widget shows the error; tap it to open the script.",
            "Installed gems aren't available to widget scripts yet. The bundled sqlite3 is.",
            "Device::Clipboard isn't available in widget scripts. Device::Notification works once notifications are allowed in the app.",
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
        notes: [
            "The Ruby tab links to the API docs for the core classes and bundled libraries.",
            "Every run starts without the constants an earlier run assigned, like TOKEN = \"...\", so running a script again doesn't warn. Classes, methods and libraries loaded with require stay loaded between runs.",
        ]
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
            "On iOS, reading the clipboard shows the system paste banner. That's Apple's privacy gate, not something RubyCuts can suppress.",
            "Not available in widget scripts: a widget refreshes in the background, so it would read and overwrite the clipboard without you knowing. It raises an error there.",
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
            "The first call after installing the app raises while the system shows its permission prompt. Allow notifications, then call notify again: the second call succeeds.",
            "Widget scripts can post notifications once they're allowed, but can't ask for permission. Allow them from the app first, by running a script that calls notify.",
        ]
    )

    static let widgetUI = DocTopic(
        id: "widget-ui",
        kind: .api,
        title: "WidgetUI",
        summary: "Lay out a widget with SwiftUI-style views.",
        overview:
            "Describes a widget's layout as a tree of views, in the style of SwiftUI. Views go inside the block given to WidgetUI.new, and modifiers chain onto them. Available in every script without a require. See the Widgets guide for putting the result on the Home Screen.",
        members: [
            DocMember(
                signature: "WidgetUI.new { ... }",
                explanation:
                    "Builds a layout from the views called inside the block. Several top-level views are stacked vertically."
            ),
            DocMember(
                signature: ".present(refresh_after: nil)",
                explanation:
                    "Makes this the layout the widget and the console preview show. Call it once, at the end; if it's called more than once, the last call wins. refresh_after asks the widget to run the script again after that many seconds, at least 300; without it the widget asks for every 15 minutes."
            ),
            DocMember(
                signature: "WidgetUI.family",
                explanation:
                    "The size being drawn: :small, :medium or :large. Use it to show more on bigger widgets. Outside a widget or the console preview, e.g. from Shortcuts, it's :medium."
            ),
            DocMember(
                signature: "HStack(alignment: :center, spacing: nil) { ... }",
                explanation: "Lays views out side by side. alignment is :top, :center or :bottom."),
            DocMember(
                signature: "VStack(alignment: :center, spacing: nil) { ... }",
                explanation: "Lays views out top to bottom. alignment is :leading, :center or :trailing."),
            DocMember(
                signature: "ZStack(alignment: :center) { ... }",
                explanation:
                    "Layers views on top of each other. alignment is :center, :top, :bottom, :leading, :trailing or a corner such as :top_leading or :bottom_trailing."
            ),
            DocMember(signature: "Text(string)", explanation: "A line of text."),
            DocMember(
                signature: "Image(system: \"name\")",
                explanation: "An SF Symbol, e.g. \"bolt.fill\". Size it with font or size."),
            DocMember(
                signature: "Spacer()",
                explanation: "Fills the free space in a stack, pushing the other views apart."),
            DocMember(signature: "Divider()", explanation: "A thin separator line."),
            DocMember(
                signature: ".padding(16)",
                explanation:
                    "Adds space around the view, 16 points by default. padding_top, padding_bottom, padding_leading and padding_trailing pad one edge; padding_left and padding_right are the same as leading and trailing."
            ),
            DocMember(
                signature: ".frame(width: nil, height: nil)",
                explanation: "Sets the size in points, or :infinity to fill the available space."),
            DocMember(
                signature: ".background(color)",
                explanation: "Paints a color behind the view. An array of colors paints a top-to-bottom gradient."),
            DocMember(
                signature: ".color(color)",
                explanation: "Sets the color of text and symbols. Also called foreground_color."),
            DocMember(
                signature: ".font(:headline)",
                explanation:
                    "A text style: :large_title, :title, :title2, :title3, :headline, :subheadline, :body, :callout, :footnote, :caption or :caption2."
            ),
            DocMember(signature: ".size(points)", explanation: "A font size in points."),
            DocMember(signature: ".bold, .italic", explanation: "Bold or italic text."),
            DocMember(signature: ".opacity(0.5)", explanation: "Makes the view partly transparent, from 0 to 1."),
            DocMember(signature: ".corner_radius(12)", explanation: "Rounds the view's corners."),
        ],
        examples: [
            DocExample(
                title: "A gradient card",
                code: #"""
                    WidgetUI.new do
                      VStack(alignment: :leading, spacing: 4) {
                        Image(system: "bolt.fill").font(:title2)
                        Spacer()
                        Text("Battery").font(:caption).opacity(0.8)
                        Text("82 %").font(:title).bold
                      }
                      .padding
                      .frame(width: :infinity, height: :infinity)
                      .color(:white)
                      .background(["#34C759", "#248A3D"])
                    end.present
                    """#,
                verification: .runs()),
            DocExample(
                title: "A layout for each size",
                code: #"""
                    WidgetUI.new do
                      VStack(alignment: :leading) {
                        Text("Inbox").font(:headline)
                        Text("12 unread").font(:caption)
                        if WidgetUI.family != :small
                          Spacer()
                          Text("Latest: Lunch on Friday?").font(:footnote)
                        end
                      }
                      .padding
                      .frame(width: :infinity, height: :infinity)
                    end.present(refresh_after: 30 * 60)
                    """#,
                verification: .runs()),
            DocExample(
                title: "Rows from data",
                code: #"""
                    tasks = { "Water plants" => true, "Pay rent" => false, "Call mum" => false }

                    WidgetUI.new do
                      VStack(alignment: :leading, spacing: 6) {
                        Text("Today").font(:headline)
                        tasks.each do |name, done|
                          HStack {
                            Image(system: done ? "checkmark.circle.fill" : "circle")
                            Text(name).opacity(done ? 0.5 : 1)
                          }
                        end
                        Spacer()
                      }
                      .padding
                      .frame(width: :infinity, height: :infinity)
                    end.present
                    """#,
                verification: .runs()),
        ],
        notes: [
            "Colors are a symbol (:white, :black, :gray, :red, :orange, :yellow, :green, :mint, :teal, :cyan, :blue, :indigo, :purple, :pink, :brown, :clear, :primary, :secondary) or a hex string such as \"#FF8800\", or \"#FF880080\" with transparency.",
            "Modifiers apply in the order you write them, as in SwiftUI: .padding.background(:blue) puts the padding inside the blue area, .background(:blue).padding puts it outside.",
            "The layout fills the whole widget, edge to edge, so add .padding to keep content away from the edges.",
            "A wrong argument raises an error naming the allowed values, e.g. unknown color :chartreuse.",
        ]
    )
}
