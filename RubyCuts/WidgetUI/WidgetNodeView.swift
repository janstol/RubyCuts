import SwiftUI

/// Draws a ``WidgetNode`` tree with SwiftUI. Shared by the widget extension and the app's preview.
struct WidgetNodeView: View {
    var node: WidgetNode

    var body: some View {
        node.modifiers.reduce(AnyView(content)) { view, modifier in
            modifier.apply(to: view)
        }
    }

    @ViewBuilder private var content: some View {
        let children = node.children ?? []
        switch node.type {
        case .hstack:
            HStack(alignment: verticalAlignment, spacing: spacing) { childViews(children) }
        case .vstack:
            VStack(alignment: horizontalAlignment, spacing: spacing) { childViews(children) }
        case .zstack:
            ZStack(alignment: alignment) { childViews(children) }
        case .text:
            Text(node.text ?? "")
        case .image:
            Image(systemName: node.system ?? "questionmark")
        case .spacer:
            Spacer(minLength: 0)
        case .divider:
            Divider()
        }
    }

    private func childViews(_ children: [WidgetNode]) -> some View {
        ForEach(children.indices, id: \.self) { index in
            WidgetNodeView(node: children[index])
        }
    }

    private var spacing: CGFloat? { node.spacing.map { CGFloat($0) } }

    private var verticalAlignment: VerticalAlignment {
        switch node.alignment {
        case "top": .top
        case "bottom": .bottom
        default: .center
        }
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch node.alignment {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }

    private var alignment: Alignment {
        switch node.alignment {
        case "top_leading": .topLeading
        case "top": .top
        case "top_trailing": .topTrailing
        case "leading": .leading
        case "trailing": .trailing
        case "bottom_leading": .bottomLeading
        case "bottom": .bottom
        case "bottom_trailing": .bottomTrailing
        default: .center
        }
    }
}

extension WidgetModifier {
    /// Wraps `view` in the SwiftUI modifier this case describes.
    fileprivate func apply(to view: AnyView) -> AnyView {
        switch self {
        case .padding(let edges, let amount):
            AnyView(view.padding(edges.swiftUIEdges, CGFloat(amount)))
        case .frame(let width, let height):
            AnyView(
                view
                    .frame(width: width?.points, height: height?.points)
                    .frame(
                        maxWidth: width == .infinity ? .infinity : nil,
                        maxHeight: height == .infinity ? .infinity : nil))
        case .background(.color(let color)):
            AnyView(view.background(color.swiftUIColor))
        case .background(.gradient(let colors)):
            AnyView(
                view.background(
                    LinearGradient(
                        colors: colors.map(\.swiftUIColor), startPoint: .top, endPoint: .bottom)))
        case .foregroundColor(let color):
            AnyView(view.foregroundStyle(color.swiftUIColor))
        case .cornerRadius(let radius):
            AnyView(view.clipShape(RoundedRectangle(cornerRadius: CGFloat(radius))))
        case .opacity(let value):
            AnyView(view.opacity(value))
        case .font(let style):
            AnyView(view.font(style.swiftUIFont))
        case .size(let points):
            AnyView(view.font(.system(size: CGFloat(points))))
        case .bold:
            AnyView(view.bold())
        case .italic:
            AnyView(view.italic())
        }
    }
}

extension WidgetModifier.Edges {
    fileprivate var swiftUIEdges: Edge.Set {
        switch self {
        case .all: .all
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}

extension WidgetModifier.TextStyle {
    fileprivate var swiftUIFont: Font {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        }
    }
}

extension WidgetDimension {
    fileprivate var points: CGFloat? {
        if case .points(let value) = self { CGFloat(value) } else { nil }
    }
}

extension WidgetColor {
    fileprivate var swiftUIColor: Color {
        switch self {
        case .rgba(let red, let green, let blue, let alpha):
            Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
        case .named(let name):
            switch name {
            case "white": .white
            case "black": .black
            case "gray": .gray
            case "red": .red
            case "orange": .orange
            case "yellow": .yellow
            case "green": .green
            case "mint": .mint
            case "teal": .teal
            case "cyan": .cyan
            case "blue": .blue
            case "indigo": .indigo
            case "purple": .purple
            case "pink": .pink
            case "brown": .brown
            case "clear": .clear
            case "secondary": .secondary
            default: .primary
            }
        }
    }
}

#Preview {
    let json = """
        {"version":1,"root":{"type":"vstack","alignment":"leading","spacing":4,"modifiers":[
          {"name":"padding","edges":"all","amount":16},
          {"name":"frame","width":"infinity","height":"infinity"},
          {"name":"background","fill":{"gradient":[{"hex":"F14034"},{"hex":"AD2323"}]}},
          {"name":"corner_radius","radius":22}],
        "children":[
          {"type":"hstack","alignment":"center","modifiers":[],"children":[
            {"type":"image","system":"bitcoinsign.circle.fill","modifiers":[{"name":"size","points":28}]},
            {"type":"spacer","modifiers":[]}]},
          {"type":"spacer","modifiers":[]},
          {"type":"text","text":"$97,412","modifiers":[{"name":"font","style":"title"},{"name":"bold"}]},
          {"type":"text","text":"updated 09:15","modifiers":[{"name":"font","style":"caption"},{"name":"opacity","value":0.8}]}]}}
        """
    if let layout = try? WidgetLayout.decode(json: json) {
        WidgetNodeView(node: layout.root)
            .foregroundStyle(.white)
            .frame(width: 170, height: 170)
    }
}
