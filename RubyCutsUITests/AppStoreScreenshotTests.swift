#if os(iOS)
    import XCTest

    /// Captures the App Store screenshots on whichever iOS simulator it runs on.
    ///
    /// Skipped unless the runner's environment has `SCREENSHOTS=1` (pass
    /// `TEST_RUNNER_SCREENSHOTS=1` to `xcodebuild`), so the regular test run
    /// doesn't pay for it or hit the network. Each scene relaunches the app
    /// with `-UIScreenshots`, which swaps in the app's debug-only screenshot
    /// fixture library, then sets the appearance (and the orientation on
    /// iPad), navigates and attaches a screenshot of every screen named
    /// `NN-scene-light|dark`. Picking the PNGs out of the result bundle,
    /// checking their sizes and the status bar override are the host's job.
    final class AppStoreScreenshotTests: XCTestCase {
        private var app: XCUIApplication!

        override func setUpWithError() throws {
            try XCTSkipUnless(
                ProcessInfo.processInfo.environment["SCREENSHOTS"] == "1",
                "Set TEST_RUNNER_SCREENSHOTS=1 to capture App Store screenshots.")
            continueAfterFailure = false
        }

        @MainActor
        func testCaptureScreenshots() throws {
            defer { resetDevice() }
            if UIDevice.current.userInterfaceIdiom == .pad {
                try captureIPadScenes()
            } else {
                try captureIPhoneScenes()
            }
        }

        /// Puts the simulator back the way the other UI tests expect it.
        @MainActor
        private func resetDevice() {
            app?.terminate()
            XCUIDevice.shared.appearance = .light
            if UIDevice.current.userInterfaceIdiom == .pad {
                XCUIDevice.shared.orientation = .portrait
            }
        }

        // MARK: - Scenes

        @MainActor
        private func captureIPhoneScenes() throws {
            launch(appearance: .light)
            capture("01-list", appearance: .light)

            launch(appearance: .dark)
            openScript("JSON Output")
            capture("02-editor", appearance: .dark)

            launch(appearance: .light)
            openScript("Fetch JSON")
            run(waitingFor: "Completed:")
            capture("03-console", appearance: .light)

            launch(appearance: .dark)
            let documentationTab = app.buttons["Documentation"]
            XCTAssertTrue(documentationTab.waitForExistence(timeout: 10))
            documentationTab.tap()
            // A topic page rather than the documentation's landing list,
            // which lists the Gems guide: no gems in store screenshots.
            let topic = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Input: ARGV")
            ).firstMatch
            XCTAssertTrue(topic.waitForExistence(timeout: 10))
            topic.tap()
            XCTAssertTrue(
                app.navigationBars["Input: ARGV, STDIN, ENV"].waitForExistence(timeout: 10))
            capture("04-documentation", appearance: .dark)
        }

        @MainActor
        private func captureIPadScenes() throws {
            // Both landscape: the App Store shows every screenshot in the
            // first one's orientation, so a mix ends up sideways.
            launch(appearance: .light, orientation: .landscapeLeft)
            openScript("Fetch JSON")
            run(waitingFor: "Completed:")
            capture("01-main", appearance: .light)

            launch(appearance: .dark, orientation: .landscapeLeft)
            openScript("Hello Shortcuts")
            run(waitingFor: "GREETING from Environment:")
            capture("02-shortcuts", appearance: .dark)
        }

        // MARK: - Steps

        /// Sets the device up and (re)launches the app over a fresh fixture
        /// library, then waits for the list to show.
        @MainActor
        private func launch(
            appearance: XCUIDevice.Appearance, orientation: UIDeviceOrientation? = nil
        ) {
            app?.terminate()
            XCUIDevice.shared.appearance = appearance
            if let orientation {
                XCUIDevice.shared.orientation = orientation
            }
            app = XCUIApplication()
            app.launchArguments = ["-UIScreenshots"]
            app.launch()
            XCTAssertTrue(row(named: "Fetch JSON").waitForExistence(timeout: 20))
        }

        /// The list row for a script. Rows combine their name and date into
        /// one accessibility label, "Name, modified …".
        @MainActor
        private func row(named name: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", "\(name), modified"))
                .firstMatch
        }

        /// Opens a script in the editor and waits for its source to load.
        @MainActor
        private func openScript(_ name: String) {
            row(named: name).tap()
            let source = app.textViews["Script Source"]
            XCTAssertTrue(source.waitForExistence(timeout: 10))
            let loaded = NSPredicate(format: "value CONTAINS %@", "# \(name)")
            expectation(for: loaded, evaluatedWith: source)
            waitForExpectations(timeout: 10)
        }

        /// Runs the open script and waits for `text` to show in the console.
        @MainActor
        private func run(waitingFor text: String) {
            let runButton = app.buttons["Run"]
            XCTAssertTrue(runButton.waitForExistence(timeout: 10))
            runButton.tap()
            let output = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", text))
                .firstMatch
            XCTAssertTrue(output.waitForExistence(timeout: 30), "No \"\(text)\" in the console")
            // The Run button only comes back once the run has finished.
            XCTAssertTrue(runButton.waitForExistence(timeout: 10))
        }

        /// Attaches a screenshot of every screen. A device with one screen
        /// gets `name-appearance`; one with several (the iPhone Duo) gets
        /// `name-appearance@screenN`, and the host drops the blank ones.
        @MainActor
        private func capture(_ name: String, appearance: XCUIDevice.Appearance) {
            // Lets transitions and the console's appearance finish.
            Thread.sleep(forTimeInterval: 1.5)
            let suffix = appearance == .dark ? "dark" : "light"
            let screens = XCUIScreen.screens
            for (index, screen) in screens.enumerated() {
                let attachment = Self.uprightAttachment(for: screen.screenshot())
                attachment.name =
                    screens.count == 1
                    ? "\(name)-\(suffix)" : "\(name)-\(suffix)@screen\(index)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }

        /// A landscape screenshot comes back as portrait pixels plus an EXIF
        /// rotation, which App Store Connect can't be trusted to apply, and
        /// the iPhone Duo's inner display comes back one pixel short each
        /// way (2852×2006 instead of 2853×2007). This redraws such a
        /// screenshot upright at the full size, repeating the last row and
        /// column of pixels; a clean one is attached as is.
        @MainActor
        private static func uprightAttachment(for screenshot: XCUIScreenshot) -> XCTAttachment {
            let image = screenshot.image
            // Screens are a whole number of points; the short screenshot isn't.
            let fullSize = CGSize(
                width: image.size.width.rounded(.up), height: image.size.height.rounded(.up))
            guard image.imageOrientation != .up || fullSize != image.size else {
                return XCTAttachment(screenshot: screenshot)
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            format.opaque = true
            format.preferredRange = .standard
            let upright = UIGraphicsImageRenderer(size: fullSize, format: format).pngData {
                _ in
                // The shifted copy underneath only shows through in the gap.
                image.draw(
                    at: CGPoint(
                        x: fullSize.width - image.size.width,
                        y: fullSize.height - image.size.height))
                image.draw(at: .zero)
            }
            return XCTAttachment(data: upright, uniformTypeIdentifier: "public.png")
        }
    }
#endif
