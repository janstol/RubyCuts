import AppIntents
import SwiftUI
import WidgetKit

/// A Home Screen / desktop widget that runs one of the user's scripts and draws the layout it presents with `WidgetUI`.
///
/// The script runs inside the extension each time WidgetKit asks for a timeline, so the widget refreshes on its own; the app also asks WidgetKit to reload after running a script that presents a layout. The layout fills the widget edge to edge (content margins are off), so scripts add their own `.padding`.
struct ScriptWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "Script", intent: SelectScriptIntent.self, provider: ScriptTimelineProvider()
        ) { entry in
            ScriptWidgetView(content: entry.content)
                .containerBackground(.fill.tertiary, for: .widget)
                // Tapping opens the script in the app, including when it shows an error.
                .widgetURL(entry.scriptFileName.map(ScriptLink.url(forFileName:)))
        }
        .configurationDisplayName("Ruby Script")
        .description("Shows the layout a script builds with WidgetUI.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

/// The widget's configuration: which script to run.
struct SelectScriptIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Script"

    static var description: IntentDescription? {
        IntentDescription("Pick the script whose WidgetUI layout the widget shows.")
    }

    @Parameter(title: "Script")
    var script: ScriptEntity?
}

/// One widget refresh.
nonisolated struct ScriptEntry: TimelineEntry {
    var date: Date
    var content: ScriptWidgetContent
    /// The configured script's file name, for the tap link. `nil` before a script is chosen and for the gallery sample.
    var scriptFileName: String?
}

/// Runs the configured script for each timeline. Placeholders and the widget gallery get a static sample instead, so browsing the gallery doesn't run anything.
nonisolated struct ScriptTimelineProvider: AppIntentTimelineProvider {
    /// How long until WidgetKit is asked to refresh again. The system treats this as a lower bound and may wait longer.
    static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> ScriptEntry {
        ScriptEntry(date: .now, content: .layout(.sample))
    }

    func snapshot(for configuration: SelectScriptIntent, in context: Context) async -> ScriptEntry {
        if context.isPreview {
            return ScriptEntry(date: .now, content: .layout(.sample))
        }
        return await entry(for: configuration)
    }

    func timeline(for configuration: SelectScriptIntent, in context: Context) async -> Timeline<
        ScriptEntry
    > {
        return Timeline(
            entries: [await entry(for: configuration)],
            policy: .after(.now.addingTimeInterval(Self.refreshInterval)))
    }

    private func entry(for configuration: SelectScriptIntent) async -> ScriptEntry {
        ScriptEntry(
            date: .now, content: await ScriptWidgetRunner.content(for: configuration.script),
            scriptFileName: configuration.script?.id)
    }
}

/// Draws a ``ScriptWidgetContent``.
struct ScriptWidgetView: View {
    var content: ScriptWidgetContent

    var body: some View {
        switch content {
        case .layout(let layout):
            WidgetNodeView(node: layout.root)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .message(let symbol, let title, let detail):
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
        }
    }
}

nonisolated extension WidgetLayout {
    /// A static layout for placeholders, the widget gallery and previews.
    static let sample: WidgetLayout = {
        let json = """
            {"version":1,"root":{"type":"vstack","alignment":"leading","spacing":2,"modifiers":[
              {"name":"padding","edges":"all","amount":16},
              {"name":"frame","width":"infinity","height":"infinity"},
              {"name":"foreground_color","color":{"named":"white"}},
              {"name":"background","fill":{"gradient":[{"hex":"E0115F"},{"hex":"9B1B30"}]}}],
            "children":[
              {"type":"image","system":"diamond.fill","modifiers":[{"name":"font","style":"title2"}]},
              {"type":"spacer","modifiers":[]},
              {"type":"text","text":"Hello from Ruby","modifiers":[{"name":"font","style":"headline"}]},
              {"type":"text","text":"WidgetUI.new { ... }.present","modifiers":[
                {"name":"font","style":"caption2"},{"name":"opacity","value":0.8}]}]}}
            """
        do {
            return try WidgetLayout.decode(json: json)
        } catch {
            preconditionFailure("WidgetLayout.sample doesn't decode: \(error)")
        }
    }()
}

#Preview(as: .systemSmall) {
    ScriptWidget()
} timeline: {
    ScriptEntry(date: .now, content: .layout(.sample))
    ScriptEntry(
        date: .now,
        content: .message(
            symbol: "exclamationmark.triangle", title: "weather failed",
            detail: "undefined method 'fetch' for nil"))
}
