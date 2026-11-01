import SwiftUI

/// The in-app documentation: an index of RubyCuts guides and API modules that
/// drill into detail pages, plus a Ruby tab linking to the official Ruby docs
/// for the core classes and bundled libraries.
///
/// Content-only, matching ``GemListView``: a `List` with a
/// `.navigationTitle`, no navigation chrome or sizing frame of its own. The
/// host supplies the `NavigationStack`: a sheet from ``ScriptListView`` on
/// iOS/iPadOS, a dedicated `Window` scene reached from the Help menu on macOS.
struct DocumentationView: View {
    /// The two tabs of the segmented control at the top of the index.
    enum Tab: Hashable {
        case rubyCuts
        case ruby
    }

    @State private var tab: Tab = .rubyCuts
    @State private var searchText = ""

    var body: some View {
        List {
            Picker("Documentation", selection: $tab) {
                Text("RubyCuts").tag(Tab.rubyCuts)
                Text("Ruby").tag(Tab.ruby)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            switch tab {
            case .rubyCuts:
                topicSection("Guides", topics: matching(DocCatalog.guides))
                topicSection("API", topics: matching(DocCatalog.api))
            case .ruby:
                rubySection("Core", links: matching(RubyDocLink.core))
                rubySection("Libraries", links: matching(RubyDocLink.libraries))
            }
        }
        .navigationTitle("Documentation")
        .searchable(text: $searchText)
        .navigationDestination(for: DocTopic.self) { topic in
            DocTopicView(topic: topic)
        }
    }

    @ViewBuilder
    private func topicSection(_ title: String, topics: [DocTopic]) -> some View {
        if !topics.isEmpty {
            Section(title) {
                ForEach(topics) { topic in
                    NavigationLink(value: topic) {
                        IndexRow(
                            title: topic.title, summary: topic.summary,
                            monospaced: topic.kind == .api)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rubySection(_ title: String, links: [RubyDocLink]) -> some View {
        if !links.isEmpty {
            Section(title) {
                ForEach(links) { link in
                    Link(destination: link.url) {
                        HStack {
                            IndexRow(title: link.name, summary: link.summary, monospaced: true)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func matching(_ topics: [DocTopic]) -> [DocTopic] {
        topics.filter { Self.matches(searchText, title: $0.title, summary: $0.summary) }
    }

    private func matching(_ links: [RubyDocLink]) -> [RubyDocLink] {
        links.filter { Self.matches(searchText, title: $0.name, summary: $0.summary) }
    }

    /// `true` when `query` is blank or appears in `title` or `summary`,
    /// ignoring case and diacritics.
    nonisolated static func matches(_ query: String, title: String, summary: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return title.localizedStandardContains(trimmed)
            || summary.localizedStandardContains(trimmed)
    }
}

/// An index row: the title above its one-line summary.
private struct IndexRow: View {
    let title: String
    let summary: String
    let monospaced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        DocumentationView()
    }
}
