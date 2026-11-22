import SwiftUI

/// Shows a script's presented widget layout in the console at small and medium widget sizes, so a widget script can be checked without going to the Home Screen.
struct WidgetPreviewView: View {
    /// The JSON from ``RunResult/presentedLayoutJSON``.
    let layoutJSON: String

    /// Approximate small and medium widget sizes on a current iPhone. Only for previewing; the real widget gets whatever size the system gives it.
    private static let sizes: [(name: String, size: CGSize)] = [
        ("Small", CGSize(width: 170, height: 170)),
        ("Medium", CGSize(width: 364, height: 170)),
    ]

    var body: some View {
        switch Result(catching: { try WidgetLayout.decode(json: layoutJSON) }) {
        case .success(let layout):
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Self.sizes, id: \.name) { entry in
                        VStack(spacing: 4) {
                            WidgetNodeView(node: layout.root)
                                .frame(width: entry.size.width, height: entry.size.height)
                                .background(.fill.tertiary)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            Text(entry.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Widget preview")
        case .failure(let error):
            Text("Couldn't draw the widget: \(String(describing: error))")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    WidgetPreviewView(
        layoutJSON: """
            {"version":1,"root":{"type":"vstack","alignment":"leading","modifiers":[
              {"name":"padding","edges":"all","amount":16},
              {"name":"frame","width":"infinity","height":"infinity"},
              {"name":"foreground_color","color":{"named":"white"}},
              {"name":"background","fill":{"gradient":[{"hex":"F14034"},{"hex":"AD2323"}]}}],
            "children":[
              {"type":"spacer","modifiers":[]},
              {"type":"text","text":"97,412","modifiers":[{"name":"font","style":"title"},{"name":"bold"}]}]}}
            """
    )
    .padding()
}
