import Foundation

/// The Ruby half of the widget DSL: defines `WidgetUI`, which a script uses to describe a widget layout as a SwiftUI-like tree.
///
/// ```ruby
/// WidgetUI.new do
///   VStack(alignment: :leading, spacing: 4) {
///     Text("Hello").font(:headline).color(:white)
///     Spacer()
///   }
///   .padding
///   .background(["#F14034", "#AD2323"])
/// end.present
/// ```
///
/// `present` stores the tree; the host reads it back as JSON with `WidgetUI.presented_json` and decodes it into a ``WidgetLayout``. The JSON shape is the contract between the two halves, so a change here needs the matching change in ``WidgetNode``.
///
/// Modeled on Rubyist's WidgetUI so its scripts port with few changes, with two deliberate differences: colors are plain values (`:red`, `"#F14034"`, or an array of them for a gradient) rather than top-level `Color`/`Gradient` constants that would leak into every script, and modifiers apply in call order, as in SwiftUI.
nonisolated enum WidgetUIPrelude {
    /// Ruby source evaluated once at VM boot.
    static let source = #"""
        require 'json'

        class WidgetUI
          FORMAT_VERSION = 1

          NAMED_COLORS = %i[
            white black gray red orange yellow green mint teal cyan blue indigo purple pink brown
            clear primary secondary
          ].freeze
          TEXT_STYLES = %i[
            large_title title title2 title3 headline subheadline body callout footnote caption caption2
          ].freeze
          HSTACK_ALIGNMENTS = %i[top center bottom].freeze
          VSTACK_ALIGNMENTS = %i[leading center trailing].freeze
          ZSTACK_ALIGNMENTS = %i[
            top_leading top top_trailing leading center trailing bottom_leading bottom bottom_trailing
          ].freeze
          FAMILIES = %i[small medium large].freeze
          # The shortest refresh interval a script may ask for, in seconds. Shorter requests would only use up the widget's refresh budget sooner.
          MINIMUM_REFRESH = 300

          class << self
            # The layout from the most recent `present`, as a Hash, or nil.
            attr_accessor :presented

            # The presented layout as a JSON string, or nil if nothing was presented.
            def presented_json
              presented && JSON.generate(presented)
            end

            # The size of the widget being drawn: :small, :medium or :large. :medium when the script runs outside a widget or preview, e.g. from Shortcuts.
            def family
              @family_read = true
              @family || :medium
            end

            # Whether the script read `family` during this run, so the host knows a layout drawn for one size may not suit the others.
            def family_read? = @family_read == true

            # Called by the host before each run: clears the previous layout and sets the size to draw for (nil outside a widget or preview).
            def prepare_run(family)
              raise ArgumentError, "unknown widget family #{family.inspect}" unless family.nil? || FAMILIES.include?(family)
              self.presented = nil
              @family = family
              @family_read = false
            end

            def color(value)
              case value
              when Symbol
                unless NAMED_COLORS.include?(value)
                  raise ArgumentError, "unknown color :#{value}; use one of #{NAMED_COLORS.map(&:inspect).join(', ')} or a hex string like \"#FF8800\""
                end
                { 'named' => value.to_s }
              when String
                hex = value.delete_prefix('#')
                unless hex.match?(/\A(\h{6}|\h{8})\z/)
                  raise ArgumentError, "invalid hex color #{value.inspect}; expected \"#RRGGBB\" or \"#RRGGBBAA\""
                end
                { 'hex' => hex.upcase }
              else
                raise ArgumentError, "expected a color symbol or hex string, got #{value.inspect}"
              end
            end

            def fill(value)
              if value.is_a?(Array)
                raise ArgumentError, 'a gradient needs at least two colors' if value.size < 2
                { 'gradient' => value.map { |c| color(c) } }
              else
                { 'color' => color(value) }
              end
            end

            def dimension(value)
              case value
              when nil then nil
              when :infinity then 'infinity'
              when Numeric then value.to_f
              else raise ArgumentError, "expected a number or :infinity, got #{value.inspect}"
              end
            end

            def number(value, name)
              raise ArgumentError, "#{name} must be a number, got #{value.inspect}" unless value.is_a?(Numeric)
              value.to_f
            end

            def choice(value, allowed, name)
              unless allowed.include?(value)
                raise ArgumentError, "#{name} must be one of #{allowed.map(&:inspect).join(', ')}, got #{value.inspect}"
              end
              value.to_s
            end

            # Strings read from the network or a file are often BINARY even when their bytes are UTF-8, and JSON refuses those.
            def utf8(value)
              string = value.to_s
              string = string.dup.force_encoding(Encoding::UTF_8) if string.encoding == Encoding::BINARY
              string
            end
          end

          # One node of the layout tree. Every modifier returns the view itself, so they chain.
          class View
            attr_reader :children

            def initialize(type, properties = {}, children = nil)
              @type = type
              @properties = properties
              @children = children
              @modifiers = []
            end

            def padding(amount = 16) = modify('padding', 'edges' => 'all', 'amount' => WidgetUI.number(amount, 'padding'))
            def padding_top(amount = 16) = modify('padding', 'edges' => 'top', 'amount' => WidgetUI.number(amount, 'padding'))
            def padding_bottom(amount = 16) = modify('padding', 'edges' => 'bottom', 'amount' => WidgetUI.number(amount, 'padding'))
            def padding_leading(amount = 16) = modify('padding', 'edges' => 'leading', 'amount' => WidgetUI.number(amount, 'padding'))
            def padding_trailing(amount = 16) = modify('padding', 'edges' => 'trailing', 'amount' => WidgetUI.number(amount, 'padding'))
            alias padding_left padding_leading
            alias padding_right padding_trailing

            def frame(width: nil, height: nil)
              modify('frame', 'width' => WidgetUI.dimension(width), 'height' => WidgetUI.dimension(height))
            end

            def background(fill) = modify('background', 'fill' => WidgetUI.fill(fill))
            def foreground_color(color) = modify('foreground_color', 'color' => WidgetUI.color(color))
            alias color foreground_color
            def corner_radius(radius) = modify('corner_radius', 'radius' => WidgetUI.number(radius, 'corner_radius'))
            def opacity(value) = modify('opacity', 'value' => WidgetUI.number(value, 'opacity'))
            def font(style) = modify('font', 'style' => WidgetUI.choice(style, TEXT_STYLES, 'font'))
            def size(points) = modify('size', 'points' => WidgetUI.number(points, 'size'))
            def bold = modify('bold')
            def italic = modify('italic')

            def to_hash
              hash = { 'type' => @type }.merge(@properties)
              hash['modifiers'] = @modifiers
              hash['children'] = @children.map(&:to_hash) if @children
              hash
            end
            alias to_h to_hash

            private

            def modify(name, arguments = {})
              @modifiers << { 'name' => name }.merge(arguments)
              self
            end
          end

          # The receiver of the block given to `WidgetUI.new`. Each view method adds a node to the innermost open stack and returns it.
          class Builder
            def initialize
              @containers = [[]]
            end

            def roots = @containers.first

            def HStack(alignment: :center, spacing: nil, &block)
              stack('hstack', { 'alignment' => WidgetUI.choice(alignment, HSTACK_ALIGNMENTS, 'HStack alignment'), 'spacing' => spacing && WidgetUI.number(spacing, 'spacing') }, &block)
            end

            def VStack(alignment: :center, spacing: nil, &block)
              stack('vstack', { 'alignment' => WidgetUI.choice(alignment, VSTACK_ALIGNMENTS, 'VStack alignment'), 'spacing' => spacing && WidgetUI.number(spacing, 'spacing') }, &block)
            end

            def ZStack(alignment: :center, &block)
              stack('zstack', { 'alignment' => WidgetUI.choice(alignment, ZSTACK_ALIGNMENTS, 'ZStack alignment') }, &block)
            end

            def Text(text) = add(View.new('text', 'text' => WidgetUI.utf8(text)))
            def Image(system:) = add(View.new('image', 'system' => WidgetUI.utf8(system)))
            def Spacer = add(View.new('spacer'))
            def Divider = add(View.new('divider'))

            private

            def add(view)
              @containers.last << view
              view
            end

            def stack(type, properties, &block)
              view = add(View.new(type, properties.compact, []))
              @containers.push(view.children)
              begin
                block&.call
              ensure
                @containers.pop
              end
              view
            end
          end

          attr_reader :root

          # Builds the layout by evaluating the block with the view methods (HStack, Text, ...) in scope. Several top-level views are wrapped in a VStack.
          def initialize(&block)
            raise ArgumentError, 'WidgetUI.new needs a block describing the layout' unless block
            builder = Builder.new
            builder.instance_eval(&block)
            roots = builder.roots
            @root = if roots.size == 1
                      roots.first
                    else
                      View.new('vstack', { 'alignment' => 'center' }, roots)
                    end
          end

          def to_hash
            hash = { 'version' => FORMAT_VERSION, 'root' => @root.to_hash }
            hash['refresh_after'] = @refresh_after if @refresh_after
            hash
          end
          alias to_h to_hash

          # Marks this layout as the one to show. When several are presented, the last one wins. `refresh_after` asks the widget to run the script again after that many seconds (at least MINIMUM_REFRESH); the system decides the actual time.
          def present(refresh_after: nil)
            unless refresh_after.nil?
              unless refresh_after.is_a?(Numeric) && refresh_after >= MINIMUM_REFRESH
                raise ArgumentError, "refresh_after must be a number of seconds, at least #{MINIMUM_REFRESH}, got #{refresh_after.inspect}"
              end
              @refresh_after = refresh_after.to_f
            end
            WidgetUI.presented = to_hash
            self
          end
        end
        """#
}
