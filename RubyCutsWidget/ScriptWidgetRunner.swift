import Foundation

/// What a script widget shows: the layout the script presented, or a message explaining why there isn't one.
nonisolated enum ScriptWidgetContent: Hashable, Sendable {
    /// The script presented this layout.
    case layout(WidgetLayout)
    /// No layout to show. `symbol` is an SF Symbol name; `detail` may be long, so the view truncates it.
    case message(symbol: String, title: String, detail: String)
}

/// Runs a script inside the widget extension and turns the outcome into ``ScriptWidgetContent``.
nonisolated enum ScriptWidgetRunner {
    /// How long a script may run before it's cancelled. WidgetKit doesn't document how long a timeline request may take, so this stays well under a minute. Cancellation can't interrupt a blocking call such as a network read, so scripts should set their own timeouts on those too.
    static let runTimeout: Duration = .seconds(15)

    /// Loads `entity`'s source, runs it for a widget of size `family`, and returns what the widget should show.
    static func content(for entity: ScriptEntity?, family: WidgetUIFamily) async
        -> ScriptWidgetContent
    {
        guard let entity else {
            return .message(
                symbol: "hand.tap", title: "Choose a script",
                detail: "Edit the widget and pick a script that calls WidgetUI.new { ... }.present."
            )
        }

        let store = await ScriptStorage.current()
        guard let script = entity.script(in: store) else {
            return .message(
                symbol: "questionmark.folder", title: "Script not found",
                detail: "\(entity.id) is not in your library any more.")
        }

        let source: String
        do {
            source = try await store.loadSource(of: script, timeout: .seconds(10))
        } catch {
            return .message(
                symbol: "icloud.slash", title: "Couldn't read \(entity.name)",
                detail: error.localizedDescription)
        }

        // The app refreshes the notification permission when it comes to the foreground; the extension has no such moment, so read it before every run. Otherwise Device::Notification would always see it as undecided here.
        await NotificationCapability.refreshAuthorizationStatus()
        let result = await run(source, family: family)
        return content(from: result, scriptName: entity.name)
    }

    /// Maps a finished run to widget content. Split out from ``content(for:)`` so it can be reasoned about without the VM.
    static func content(from result: RunResult, scriptName: String) -> ScriptWidgetContent {
        if result.wasCancelled {
            return .message(
                symbol: "hourglass", title: "\(scriptName) took too long",
                detail: "Widget scripts are stopped after \(runTimeout.components.seconds) seconds."
            )
        }
        if let error = result.errorMessage {
            return .message(
                symbol: "exclamationmark.triangle", title: "\(scriptName) failed", detail: error)
        }
        guard let json = result.presentedLayoutJSON else {
            return .message(
                symbol: "rectangle.dashed", title: "Nothing to show",
                detail: "\(scriptName) ran but didn't call WidgetUI.new { ... }.present.")
        }
        do {
            return .layout(try WidgetLayout.decode(json: json))
        } catch {
            return .message(
                symbol: "exclamationmark.triangle", title: "Couldn't draw \(scriptName)",
                detail: "\(error)")
        }
    }

    /// Runs `source`, cancelling it after ``runTimeout``.
    private static func run(_ source: String, family: WidgetUIFamily) async -> RunResult {
        let run = Task { await RubyRuntime.shared.runCancellable(source, widgetFamily: family) }
        let timer = Task {
            try await Task.sleep(for: runTimeout)
            run.cancel()
        }
        let result = await run.value
        timer.cancel()
        return result
    }
}
