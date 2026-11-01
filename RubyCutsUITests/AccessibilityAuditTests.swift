#if os(iOS)
    import XCTest

    /// Runs Xcode's accessibility audit (`performAccessibilityAudit`) over the
    /// app's main screens on whichever iOS simulator it runs on: the script
    /// list, the editor with a finished run in the console, the documentation
    /// list and a topic, Settings and the gem list.
    ///
    /// Each test walks the same screens under one condition (light, dark, or
    /// a large accessibility text size), collects every issue the audit finds
    /// instead of stopping at the first, attaches them as a report and fails
    /// once at the end with the full list. The app runs over the screenshot
    /// fixture library (`-UIScreenshots`), so nothing touches the real
    /// library and no script hits the network.
    ///
    /// Skipped unless the runner's environment has `A11Y_AUDIT=1` (pass
    /// `TEST_RUNNER_A11Y_AUDIT=1` to `xcodebuild`, or use
    /// `mise run test:a11y`): the audit reports issues in system controls
    /// too, so it's a report to read, not a gate for the regular test run.
    final class AccessibilityAuditTests: XCTestCase {
        private var app: XCUIApplication!

        /// Issues found so far in the current test, one line each.
        private var issues: [String] = []

        override func setUpWithError() throws {
            try XCTSkipUnless(
                ProcessInfo.processInfo.environment["A11Y_AUDIT"] == "1",
                "Set TEST_RUNNER_A11Y_AUDIT=1 to run the accessibility audit.")
            continueAfterFailure = false
            issues = []
        }

        @MainActor
        func testAuditLightAppearance() throws {
            auditPass(condition: "light", appearance: .light)
        }

        @MainActor
        func testAuditDarkAppearance() throws {
            auditPass(condition: "dark", appearance: .dark)
        }

        /// Accessibility Large is about 200% of the default body size, the
        /// bar App Store Connect's Larger Text label asks for.
        @MainActor
        func testAuditLargeAccessibilityText() throws {
            auditPass(
                condition: "large text", appearance: .light,
                contentSize: "UICTContentSizeCategoryAccessibilityL")
        }

        // MARK: - Screens

        /// Launches under one condition, audits every screen, reports what
        /// it found and puts the simulator back the way other tests expect.
        @MainActor
        private func auditPass(
            condition: String, appearance: XCUIDevice.Appearance, contentSize: String? = nil
        ) {
            defer {
                app?.terminate()
                XCUIDevice.shared.appearance = .light
            }
            launch(appearance: appearance, contentSize: contentSize)
            auditScreens(condition: condition)
            reportIssues()
        }

        /// Visits every screen in turn and audits each one.
        @MainActor
        private func auditScreens(condition: String) {
            audit("script list", condition: condition)

            openScript("Hello Shortcuts")
            run(waitingFor: "GREETING from Environment:")
            audit("editor and console", condition: condition)

            // The pushed editor hides the tab bar on iPhone; start over.
            relaunch()
            tapTab("Documentation")
            audit("documentation", condition: condition)
            let topic = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Input: ARGV")
            ).firstMatch
            XCTAssertTrue(topic.waitForExistence(timeout: 10))
            topic.tap()
            XCTAssertTrue(
                app.navigationBars["Input: ARGV, STDIN, ENV"].waitForExistence(timeout: 10))
            audit("documentation topic", condition: condition)

            tapTab("Settings")
            audit("settings", condition: condition)
            // Only there when the build has gems turned on.
            let gems = app.buttons["Gems"]
            if gems.waitForExistence(timeout: 5) {
                gems.tap()
                XCTAssertTrue(app.navigationBars["Gems"].waitForExistence(timeout: 10))
                audit("gems", condition: condition)
            }
        }

        // MARK: - Steps

        /// Sets the appearance and launches the app over a fresh fixture
        /// library, optionally at a given text size, then waits for the list.
        @MainActor
        private func launch(appearance: XCUIDevice.Appearance, contentSize: String? = nil) {
            XCUIDevice.shared.appearance = appearance
            app?.terminate()
            app = XCUIApplication()
            app.launchArguments = ["-UIScreenshots"]
            if let contentSize {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
            }
            app.launch()
            XCTAssertTrue(row(named: "Fetch JSON").waitForExistence(timeout: 20))
        }

        /// Relaunches the app with the same arguments, back on the list.
        @MainActor
        private func relaunch() {
            app.terminate()
            app.launch()
            XCTAssertTrue(row(named: "Fetch JSON").waitForExistence(timeout: 20))
        }

        /// Audits whatever is on screen, recording each issue under `screen`,
        /// and attaches a screenshot of it, since many issues name no element
        /// and the screenshot is the only way to tell what they point at.
        @MainActor
        private func audit(_ screen: String, condition: String) {
            // Lets transitions finish so the audit sees the settled screen.
            Thread.sleep(forTimeInterval: 1)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "\(condition) - \(screen)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            do {
                try app.performAccessibilityAudit { issue in
                    let element = issue.element.map { Self.describe($0) } ?? "no element"
                    self.issues.append(
                        "[\(condition)] \(screen): \(issue.compactDescription) (\(element))"
                            + " - \(issue.detailedDescription)")
                    return true
                }
            } catch {
                issues.append("[\(condition)] \(screen): audit failed to run: \(error)")
            }
        }

        /// Attaches the collected issues and fails once if there are any.
        @MainActor
        private func reportIssues() {
            guard !issues.isEmpty else { return }
            let report = XCTAttachment(string: issues.joined(separator: "\n"))
            report.name = "Accessibility audit issues"
            report.lifetime = .keepAlways
            add(report)
            XCTFail("\(issues.count) accessibility issues:\n" + issues.joined(separator: "\n"))
        }

        /// A short, readable description of the element an issue points at.
        @MainActor
        private static func describe(_ element: XCUIElement) -> String {
            let label = element.label.isEmpty ? "unlabeled" : "\"\(element.label)\""
            let identifier = element.identifier.isEmpty ? "" : " id=\(element.identifier)"
            return "\(element.elementType) \(label)\(identifier) at \(element.frame)"
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
            XCTAssertTrue(runButton.waitForExistence(timeout: 10))
        }

        /// Switches to a tab in the tab bar.
        @MainActor
        private func tapTab(_ name: String) {
            let tab =
                app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name]
            XCTAssertTrue(tab.waitForExistence(timeout: 10))
            tab.tap()
        }
    }
#endif
