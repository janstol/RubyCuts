import SwiftUI

/// Placeholder root view, shown until script discovery and editing land.
///
/// Scaffolding: the description string exists only to prove the embedded Ruby VM boots and evaluates from the UI. Phase 3 replaces this view wholesale with real script discovery.
struct ContentView: View {
    private let rubyDescription: String

    init() {
        // Not RUBY_DESCRIPTION: it's available now that rubycuts_init() completes boot via ruby_options() (see rubycuts_shim.c), but building the string from RUBY_VERSION/RUBY_PLATFORM/RUBY_RELEASE_DATE keeps this scaffolding independent of exactly which boot path set it.
        let code = "\"ruby #{RUBY_VERSION} (#{RUBY_RELEASE_DATE}) [#{RUBY_PLATFORM}]\""
        rubyDescription = (try? RubyRuntime.shared.evaluate(code)) ?? "Ruby failed to start."
    }

    /// Preview-only initializer: skips booting the VM, per the "no live calls in a preview" convention.
    fileprivate init(rubyDescription: String) {
        self.rubyDescription = rubyDescription
    }

    var body: some View {
        ContentUnavailableView(
            "No Scripts Yet",
            systemImage: "doc.text",
            description: Text(rubyDescription)
        )
    }
}

#Preview {
    ContentView(rubyDescription: "ruby 3.4.9 (2026-03-11) [arm64-darwin24]")
}
