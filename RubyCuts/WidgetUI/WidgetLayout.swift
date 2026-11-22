import Foundation

/// A widget layout produced by a script's `WidgetUI.new { ... }.present`, decoded from the JSON that ``WidgetUIPrelude`` generates.
nonisolated struct WidgetLayout: Decodable, Hashable, Sendable {
    /// The JSON format version this build understands.
    static let supportedVersion = 1

    /// The format version the layout was written with.
    var version: Int
    /// The outermost view.
    var root: WidgetNode
    /// Seconds until the script asked to be run again (`present(refresh_after:)`), or `nil` for the widget's default. The Ruby side enforces the minimum.
    var refreshAfter: Double?

    private enum CodingKeys: String, CodingKey {
        case version, root
        case refreshAfter = "refresh_after"
    }

    /// Decodes a layout from the JSON string `WidgetUI.presented_json` returns.
    /// - Throws: `WidgetLayoutError.unsupportedVersion` for a layout written by a newer format, or a `DecodingError` if the JSON doesn't match the format.
    static func decode(json: String) throws -> WidgetLayout {
        let layout = try JSONDecoder().decode(WidgetLayout.self, from: Data(json.utf8))
        guard layout.version == supportedVersion else {
            throw WidgetLayoutError.unsupportedVersion(layout.version)
        }
        return layout
    }
}

/// The widget size a script draws for, which it reads as `WidgetUI.family`. The raw values are the Ruby symbols' names.
nonisolated enum WidgetUIFamily: String, CaseIterable, Sendable {
    case small, medium, large
}

/// An error decoding a ``WidgetLayout``.
nonisolated enum WidgetLayoutError: Error, Equatable, Sendable {
    /// The layout's `version` isn't ``WidgetLayout/supportedVersion``.
    case unsupportedVersion(Int)
}

/// One view in a ``WidgetLayout`` tree.
nonisolated struct WidgetNode: Decodable, Hashable, Sendable {
    /// Which view this node is.
    nonisolated enum Kind: String, Decodable, Sendable {
        case hstack, vstack, zstack, text, image, spacer, divider
    }

    /// Which view this node is.
    var type: Kind
    /// Stack alignment as the DSL spells it (e.g. `"leading"`, `"top_trailing"`). Stacks only.
    var alignment: String?
    /// Spacing between a stack's children, or `nil` for the system default. Stacks only.
    var spacing: Double?
    /// The string a `text` node shows.
    var text: String?
    /// The SF Symbol name an `image` node shows.
    var system: String?
    /// Modifiers in the order the script applied them, innermost first.
    var modifiers: [WidgetModifier]
    /// A stack's children, `nil` for leaf views.
    var children: [WidgetNode]?
}

/// A modifier applied to a ``WidgetNode``.
nonisolated enum WidgetModifier: Decodable, Hashable, Sendable {
    /// Which edges `padding` applies to.
    nonisolated enum Edges: String, Decodable, Sendable {
        case all, top, bottom, leading, trailing
    }

    /// A text style, as the DSL spells it.
    nonisolated enum TextStyle: String, Decodable, Sendable {
        case largeTitle = "large_title"
        case title, title2, title3, headline, subheadline, body, callout, footnote, caption,
            caption2
    }

    case padding(edges: Edges, amount: Double)
    case frame(width: WidgetDimension?, height: WidgetDimension?)
    case background(WidgetFill)
    case foregroundColor(WidgetColor)
    case cornerRadius(Double)
    case opacity(Double)
    case font(TextStyle)
    case size(Double)
    case bold
    case italic

    private enum CodingKeys: String, CodingKey {
        case name, edges, amount, width, height, fill, color, radius, value, style, points
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        switch name {
        case "padding":
            self = .padding(
                edges: try container.decode(Edges.self, forKey: .edges),
                amount: try container.decode(Double.self, forKey: .amount))
        case "frame":
            self = .frame(
                width: try container.decodeIfPresent(WidgetDimension.self, forKey: .width),
                height: try container.decodeIfPresent(WidgetDimension.self, forKey: .height))
        case "background":
            self = .background(try container.decode(WidgetFill.self, forKey: .fill))
        case "foreground_color":
            self = .foregroundColor(try container.decode(WidgetColor.self, forKey: .color))
        case "corner_radius":
            self = .cornerRadius(try container.decode(Double.self, forKey: .radius))
        case "opacity":
            self = .opacity(try container.decode(Double.self, forKey: .value))
        case "font":
            self = .font(try container.decode(TextStyle.self, forKey: .style))
        case "size":
            self = .size(try container.decode(Double.self, forKey: .points))
        case "bold":
            self = .bold
        case "italic":
            self = .italic
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container, debugDescription: "unknown modifier '\(name)'")
        }
    }
}

/// A frame dimension: a fixed size in points, or as much space as the parent offers.
nonisolated enum WidgetDimension: Decodable, Hashable, Sendable {
    case points(Double)
    case infinity

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let points = try? container.decode(Double.self) {
            self = .points(points)
        } else if try container.decode(String.self) == "infinity" {
            self = .infinity
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "expected a number or \"infinity\"")
        }
    }
}

/// A color: one of the DSL's named colors, or a hex value.
nonisolated enum WidgetColor: Decodable, Hashable, Sendable {
    /// A named system color, e.g. `"red"` or `"primary"`.
    case named(String)
    /// Red, green, blue and alpha, each 0...1.
    case rgba(red: Double, green: Double, blue: Double, alpha: Double)

    private enum CodingKeys: String, CodingKey {
        case named, hex
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let name = try container.decodeIfPresent(String.self, forKey: .named) {
            self = .named(name)
            return
        }
        let hex = try container.decode(String.self, forKey: .hex)
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else {
            throw DecodingError.dataCorruptedError(
                forKey: .hex, in: container, debugDescription: "invalid hex color '\(hex)'")
        }
        let rgba = hex.count == 6 ? value << 8 | 0xFF : value
        self = .rgba(
            red: Double(rgba >> 24 & 0xFF) / 255,
            green: Double(rgba >> 16 & 0xFF) / 255,
            blue: Double(rgba >> 8 & 0xFF) / 255,
            alpha: Double(rgba & 0xFF) / 255)
    }
}

/// What a `background` modifier paints: a single color or a top-to-bottom gradient.
nonisolated enum WidgetFill: Decodable, Hashable, Sendable {
    case color(WidgetColor)
    case gradient([WidgetColor])

    private enum CodingKeys: String, CodingKey {
        case color, gradient
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let colors = try container.decodeIfPresent([WidgetColor].self, forKey: .gradient) {
            self = .gradient(colors)
        } else {
            self = .color(try container.decode(WidgetColor.self, forKey: .color))
        }
    }
}
