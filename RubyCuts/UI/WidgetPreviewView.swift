import SwiftUI

/// Shows a script's presented widget layout in the console, at a widget size picked above it, so a widget script can be checked without going to the Home Screen.
///
/// Changing the size only redraws the layout. Rebuilding it for the new size, for a script that reads `WidgetUI.family`, is up to the owner of `family` (the editor reruns the script).
struct WidgetPreviewView: View {
    /// The JSON from ``RunResult/presentedLayoutJSON``.
    let layoutJSON: String
    /// The previewed size.
    @Binding var family: WidgetUIFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Widget Size", selection: $family) {
                ForEach(WidgetUIFamily.allCases, id: \.self) { family in
                    Text(family.title).tag(family)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            preview
        }
    }

    @ViewBuilder private var preview: some View {
        switch Result(catching: { try WidgetLayout.decode(json: layoutJSON) }) {
        case .success(let layout):
            WidgetNodeView(node: layout.root)
                .frame(width: family.previewSize.width, height: family.previewSize.height)
                .background(.fill.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(family.title) widget preview")
        case .failure(let error):
            Text("Couldn't draw the widget: \(String(describing: error))")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

extension WidgetUIFamily {
    /// The name shown in the size picker.
    fileprivate var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// Approximate widget sizes on a current iPhone, in points. Only for previewing; the real widget gets whatever size the system gives it.
    fileprivate var previewSize: CGSize {
        switch self {
        case .small: CGSize(width: 170, height: 170)
        case .medium: CGSize(width: 364, height: 170)
        case .large: CGSize(width: 364, height: 382)
        }
    }
}

#Preview {
    @Previewable @State var family = WidgetUIFamily.medium
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
            """,
        family: $family
    )
    .padding()
}
