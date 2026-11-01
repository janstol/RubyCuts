#if DEBUG
    import Foundation

    /// A throwaway script library for the App Store screenshot UI test
    /// (`AppStoreScreenshotTests`), used only when the app is launched with
    /// the `-UIScreenshots` argument. Debug builds only, so none of this
    /// reaches a Release build.
    ///
    /// The library lives in a fresh temp folder with its own `UserDefaults`
    /// suite: no iCloud, no state left over from earlier runs, and no effect
    /// on the real library or its sort order. It holds the samples plus a few
    /// demo scripts, with modification dates spread over the last hour so the
    /// list reads naturally. No gems anywhere, on purpose.
    enum ScreenshotFixture {
        /// The launch argument that turns the fixture on.
        static let launchArgument = "-UIScreenshots"

        /// Extra scripts shown next to the samples, so the list looks like
        /// someone actually uses the app.
        private static let demoScripts: [SampleScripts.Sample] = [
            SampleScripts.Sample(name: "Daily Note", source: dailyNote),
            SampleScripts.Sample(name: "Daily Weather", source: dailyWeather),
            SampleScripts.Sample(name: "Rename Photos", source: renamePhotos),
        ]

        /// Minutes ago each script was last modified, by name. Anything not
        /// listed keeps the time it was written, which reads as "now".
        private static let minutesAgo: [String: Double] = [
            "Daily Note": 2,
            "Daily Weather": 9,
            "Rename Photos": 24,
            "Device Bridge": 41,
            "Fetch JSON": 47,
            "Hello Shortcuts": 52,
            "JSON Output": 58,
        ]

        /// Returns the screenshot library when the app was launched with
        /// ``launchArgument``, otherwise `nil` so the caller falls back to
        /// the real library.
        static func libraryIfRequested() -> ScriptLibrary? {
            guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return nil }

            let directory = FileManager.default.temporaryDirectory
                .appending(component: "RubyCutsScreenshots-\(UUID().uuidString)")
            let store = ScriptStore(directoryURL: directory)
            let suiteName = "RubyCutsScreenshots-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            let library = ScriptLibrary(store: store, defaults: defaults)

            // Seeds the samples into the empty folder first; seeding is
            // skipped once anything else is in it.
            library.seedSamplesIfNeeded()
            for demo in demoScripts {
                _ = try? store.create(name: demo.name, source: demo.source)
            }
            backdate(store)
            library.refresh()
            return library
        }

        /// Sets each script's modification date from ``minutesAgo``.
        private static func backdate(_ store: ScriptStore) {
            guard let scripts = try? store.list() else { return }
            for script in scripts {
                guard let minutes = minutesAgo[script.name] else { continue }
                let date = Date.now.addingTimeInterval(-minutes * 60)
                try? FileManager.default.setAttributes(
                    [.modificationDate: date], ofItemAtPath: script.url.path)
            }
        }

        private static let dailyNote = """
            # Daily Note
            #
            # Builds today's journal heading for a Shortcut that appends it to
            # a note. Pass extra tags as ARGV entries.

            today = Time.now
            tags = ARGV.map { |tag| "##{tag}" }.join(" ")

            puts "## #{today.strftime("%A, %B %-d")}"
            puts tags unless tags.empty?
            puts
            puts "- "
            """

        private static let dailyWeather = """
            # Daily Weather
            #
            # Turns the weather a Shortcut passes on STDIN (as JSON) into a
            # one-line summary for a morning notification.

            require "json"

            weather = JSON.parse($stdin.read)
            high = weather.fetch("high").round
            low = weather.fetch("low").round

            puts "#{weather["summary"]}, #{low}° to #{high}°"
            puts "Take an umbrella." if weather["rain"].to_f > 0.4
            """

        private static let renamePhotos = """
            # Rename Photos
            #
            # Gets photo file names from a Shortcut (one per line on STDIN) and
            # prints a dated name for each, ready for "Rename File".

            prefix = ENV.fetch("PREFIX", "Trip")

            $stdin.each_line.with_index(1) do |line, index|
              ext = File.extname(line.strip).downcase
              puts format("%s %s %03d%s", prefix, Time.now.strftime("%Y-%m-%d"), index, ext)
            end
            """
    }
#endif
