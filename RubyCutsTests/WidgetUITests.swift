import Foundation
@testable import RubyCuts
import Testing

// Drives the shared VM, so it's nested under EmbeddedRubyTests for the same serialized execution as the other VM suites; see that type's doc comment.
extension EmbeddedRubyTests {
    @Suite(.serialized)
    struct WidgetUITests {
        /// Runs `script` (after clearing any earlier presented layout) and decodes what it presented.
        private func present(_ script: String) async throws -> WidgetLayout {
            _ = try await RubyRuntime.shared.evaluate("WidgetUI.presented = nil")
            _ = try await RubyRuntime.shared.evaluate(script)
            let json = try await RubyRuntime.shared.evaluate("WidgetUI.presented_json")
            return try WidgetLayout.decode(json: json)
        }

        /// Runs `script` and returns the error message it raised.
        private func errorMessage(_ script: String) async -> String? {
            do {
                _ = try await RubyRuntime.shared.evaluate(script)
                return nil
            } catch RubyError.evaluationFailed(let message) {
                return message
            } catch {
                return "\(error)"
            }
        }

        @Test func rubyistStyleLayoutRoundTrips() async throws {
            let layout = try await present(
                """
                WidgetUI.new do
                  HStack {
                    Spacer()
                    VStack(alignment: :center) {
                      Text("💸").size(65)
                      Spacer()
                      Text("97,412")
                    }
                    Spacer()
                  }
                  .background(["#F14034", "#AD2323"])
                  .frame(width: :infinity, height: :infinity)
                  .padding(15)
                end.present
                """)

            #expect(layout.version == 1)
            let root = layout.root
            #expect(root.type == .hstack)
            #expect(root.alignment == "center")
            #expect(root.children?.map(\.type) == [.spacer, .vstack, .spacer])
            let red: WidgetColor = .rgba(
                red: 241.0 / 255, green: 64.0 / 255, blue: 52.0 / 255, alpha: 1)
            let darkRed: WidgetColor = .rgba(
                red: 173.0 / 255, green: 35.0 / 255, blue: 35.0 / 255, alpha: 1)
            let expected: [WidgetModifier] = [
                .background(.gradient([red, darkRed])),
                .frame(width: .infinity, height: .infinity),
                .padding(edges: .all, amount: 15),
            ]
            #expect(root.modifiers == expected)

            let column = try #require(root.children?[1])
            #expect(column.children?.first?.text == "💸")
            #expect(column.children?.first?.modifiers == [.size(65)])
            #expect(column.children?.last?.text == "97,412")
        }

        @Test func everyModifierDecodesInCallOrder() async throws {
            let layout = try await present(
                """
                WidgetUI.new do
                  Text("hi")
                    .padding
                    .padding_top(1).padding_bottom(2).padding_left(3).padding_right(4)
                    .frame(width: 100)
                    .background(:blue)
                    .color("#00FF0080")
                    .corner_radius(8)
                    .opacity(0.5)
                    .font(:large_title)
                    .bold
                    .italic
                end.present
                """)

            let expected: [WidgetModifier] = [
                .padding(edges: .all, amount: 16),
                .padding(edges: .top, amount: 1),
                .padding(edges: .bottom, amount: 2),
                .padding(edges: .leading, amount: 3),
                .padding(edges: .trailing, amount: 4),
                .frame(width: .points(100), height: nil),
                .background(.color(.named("blue"))),
                .foregroundColor(.rgba(red: 0, green: 1, blue: 0, alpha: 128.0 / 255)),
                .cornerRadius(8),
                .opacity(0.5),
                .font(.largeTitle),
                .bold,
                .italic,
            ]
            #expect(layout.root.modifiers == expected)
        }

        @Test func stacksCarryAlignmentAndSpacing() async throws {
            let layout = try await present(
                """
                WidgetUI.new do
                  ZStack(alignment: :bottom_trailing) {
                    VStack(alignment: :leading, spacing: 4) { Image(system: "bolt.fill"); Divider() }
                  }
                end.present
                """)

            #expect(layout.root.type == .zstack)
            #expect(layout.root.alignment == "bottom_trailing")
            #expect(layout.root.spacing == nil)
            let column = try #require(layout.root.children?.first)
            #expect(column.alignment == "leading")
            #expect(column.spacing == 4)
            #expect(column.children?.map(\.type) == [.image, .divider])
            #expect(column.children?.first?.system == "bolt.fill")
        }

        @Test func severalTopLevelViewsAreWrappedInAVStack() async throws {
            let layout = try await present(#"WidgetUI.new { Text("a"); Text("b") }.present"#)
            #expect(layout.root.type == .vstack)
            #expect(layout.root.children?.compactMap(\.text) == ["a", "b"])
        }

        @Test func helperMethodsAndLoopsBuildViews() async throws {
            let layout = try await present(
                """
                def row(label) = Text(label).font(:caption)
                WidgetUI.new do
                  VStack { %w[x y z].each { |label| row(label) } }
                end.present
                """)
            #expect(layout.root.children?.compactMap(\.text) == ["x", "y", "z"])
        }

        @Test func binaryStringsFromTheNetworkAreAccepted() async throws {
            // Net::HTTP bodies come back BINARY even when they're UTF-8.
            let layout = try await present(
                #"WidgetUI.new { Text("caf\xC3\xA9".b) }.present"#)
            #expect(layout.root.text == "café")
        }

        @Test func lastPresentWins() async throws {
            let layout = try await present(
                #"WidgetUI.new { Text("first") }.present; WidgetUI.new { Text("second") }.present"#)
            #expect(layout.root.text == "second")
        }

        @Test func nothingPresentedGivesNoJSON() async throws {
            _ = try await RubyRuntime.shared.evaluate("WidgetUI.presented = nil")
            _ = try await RubyRuntime.shared.evaluate(#"WidgetUI.new { Text("not presented") }"#)
            let json = try await RubyRuntime.shared.evaluate("WidgetUI.presented_json.inspect")
            #expect(json == "nil")
        }

        // MARK: - RunResult.presentedLayoutJSON

        @Test func runReportsThePresentedLayout() async throws {
            let result = await RubyRuntime.shared.run(
                #"puts "hi"; WidgetUI.new { Text("from run") }.present"#)
            let json = try #require(result.presentedLayoutJSON)
            #expect(try WidgetLayout.decode(json: json).root.text == "from run")
            #expect(result.stdout == "hi\n")
        }

        @Test func aLaterRunDoesNotInheritAnEarlierLayout() async throws {
            _ = await RubyRuntime.shared.run(#"WidgetUI.new { Text("old") }.present"#)
            let result = await RubyRuntime.shared.run("1 + 1")
            #expect(result.presentedLayoutJSON == nil)
        }

        @Test func aRunThatRaisesAfterPresentingStillReportsTheError() async throws {
            let result = await RubyRuntime.shared.run(
                #"WidgetUI.new { Text("x") }.present; raise "boom""#)
            #expect(result.errorMessage?.contains("boom") == true)
            #expect(result.presentedLayoutJSON != nil)
        }

        @Test(arguments: [
            (#"WidgetUI.new { Text("x").color(:chartreuse) }"#, "unknown color :chartreuse"),
            (##"WidgetUI.new { Text("x").background("#12") }"##, ##"invalid hex color "#12""##),
            (
                #"WidgetUI.new { Text("x").background([:red]) }"#,
                "a gradient needs at least two colors"
            ),
            (#"WidgetUI.new { Text("x").font(:huge) }"#, "font must be one of"),
            (
                #"WidgetUI.new { HStack(alignment: :leading) {} }"#,
                "HStack alignment must be one of"
            ),
            (#"WidgetUI.new { Text("x").frame(width: "wide") }"#, "expected a number or :infinity"),
            (#"WidgetUI.new { Text("x").padding("lots") }"#, "padding must be a number"),
            ("WidgetUI.new", "needs a block"),
        ])
        func invalidArgumentsRaiseReadableErrors(script: String, expected: String) async throws {
            let message = try #require(await errorMessage(script))
            #expect(message.contains(expected), "got: \(message)")
        }

        // MARK: - Decoding without the VM

        @Test func rejectsANewerFormatVersion() {
            let json = #"{"version":2,"root":{"type":"spacer","modifiers":[]}}"#
            #expect(throws: WidgetLayoutError.unsupportedVersion(2)) {
                try WidgetLayout.decode(json: json)
            }
        }

        @Test func rejectsAnUnknownModifier() {
            let json = #"{"version":1,"root":{"type":"spacer","modifiers":[{"name":"blur"}]}}"#
            #expect(throws: DecodingError.self) {
                try WidgetLayout.decode(json: json)
            }
        }
    }
}
