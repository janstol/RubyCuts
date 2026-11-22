import Foundation

/// Which process a script runs in. Some native capabilities behave differently in the widget extension, which runs scripts in the background with nobody looking at the screen.
nonisolated enum ScriptHost: Sendable, Equatable {
    /// The app: the console, and Shortcuts actions.
    case app
    /// The widget extension, refreshing a Ruby Script widget.
    case widget

    /// The host of this process: the widget extension when the main bundle is an `.appex`, the app otherwise.
    static let current: ScriptHost = Bundle.main.bundleURL.pathExtension == "appex" ? .widget : .app
}
