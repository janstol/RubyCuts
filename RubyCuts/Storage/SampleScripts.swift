import Foundation

/// The scripts seeded into a fresh install (``ScriptLibrary/seedSamplesIfNeeded()``)
/// and offered back from Settings after deletion
/// (``ScriptLibrary/restoreSamples()``). Both read from ``all`` so the seeder,
/// the restore button, and ``SampleScriptsTests`` share one source of truth
/// for names and content.
///
/// Each sample is heavily commented and runnable as-is from the in-app
/// console, and names the exact Shortcuts field it reads: the
/// `@Parameter(title:)` values in `RubyIntents.swift`.
///
/// Opted out of the app target's MainActor-by-default isolation, matching
/// ``Script``/``ScriptStore``/``RunInput``: this is pure static content with
/// no actor-coupled state, usable from any context including the nonisolated
/// test target.
nonisolated enum SampleScripts {
    /// One seeded sample: a display name and its Ruby source.
    struct Sample: Sendable {
        /// The name the sample is created under, e.g. `"Hello Shortcuts"`.
        let name: String

        /// The full `.rb` source written for this sample.
        let source: String
    }

    /// Every sample seeded on first launch, in the order they're created,
    /// which is also the order ``ScriptStore/list()`` will show them in,
    /// since it sorts by name and these names are already alphabetical.
    static let all: [Sample] = [
        Sample(name: "Device Bridge", source: deviceBridge),
        Sample(name: "Fetch JSON", source: fetchJSON),
        Sample(name: "Hello Shortcuts", source: helloShortcuts),
        Sample(name: "JSON Output", source: jsonOutput),
    ]

    private static let helloShortcuts = """
        # Hello Shortcuts
        #
        # Shows the full ARGV / STDIN / Environment round-trip a Shortcut can
        # send into a script. Run this from the Shortcuts app with "Run Ruby
        # Script", picking this script, and fill in:
        #   ARGV        : add one or two list entries, e.g. "world"
        #   STDIN       : any text, piped from a previous action
        #   Environment : one KEY=value per line, e.g. GREETING=Hi
        #
        # Then run it from the in-app console with those fields empty to see
        # what "not filled in" looks like on each channel.

        puts "ARGV: #{ARGV.inspect}"
        puts "STDIN: #{$stdin.read.inspect}"
        puts "GREETING from Environment: #{ENV["GREETING"].inspect}"
        """

    private static let jsonOutput = """
        # JSON Output
        #
        # Builds a Hash and prints it as JSON, so the next Shortcut action can
        # parse structured output instead of scraping plain text: after this
        # script's action, add "Get Dictionary from Input" and feed it this
        # action's output.

        require "json"

        result = {
          "greeting" => "hello",
          "numbers" => [1, 2, 3],
          "nested" => { "ok" => true },
        }

        puts JSON.generate(result)
        """

    private static let deviceBridge = """
        # Device Bridge
        #
        # Exercises RubyCuts' native bridge: Device::Clipboard and
        # Device::Notification. No Shortcuts fields needed, run this
        # straight from the in-app console.

        Device::Clipboard.text = "Hello from RubyCuts"
        puts "Clipboard now holds: #{Device::Clipboard.text.inspect}"

        # The FIRST call to Device::Notification.notify after installing the
        # app raises here while the system shows its permission prompt in the
        # background, that's expected, not a bug. Allow the prompt, then
        # run this script again and the notification goes through.
        begin
          Device::Notification.notify("RubyCuts", "Hello from a script!")
          puts "Notification sent."
        rescue => e
          puts "Notification not sent yet: #{e.message}"
        end
        """

    private static let fetchJSON = """
        # Fetch JSON
        #
        # A live HTTPS request through the stdlib Net::HTTP, plus
        # JSON.parse. This also proves the bundled CA certificate store
        # verifies a real TLS handshake, no gem install needed for this
        # one.

        require "net/http"
        require "json"

        uri = URI("https://jsonplaceholder.typicode.com/todos/1")
        response = Net::HTTP.get(uri)
        data = JSON.parse(response)

        puts "Title: #{data["title"]}"
        puts "Completed: #{data["completed"]}"
        """
}
