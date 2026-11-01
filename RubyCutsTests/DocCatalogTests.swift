import Foundation
@testable import RubyCuts
import Testing

/// Structural checks on the documentation content: unique ids, no empty
/// index rows, and Ruby-tab links that point where we expect.
struct DocCatalogTests {
    @Test func topicIDsAreUnique() {
        let ids = DocCatalog.topics.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyTopicHasATitleAndSummary() {
        for topic in DocCatalog.topics {
            #expect(!topic.title.isEmpty, "\(topic.id) has no title")
            #expect(!topic.summary.isEmpty, "\(topic.id) has no summary")
            #expect(!topic.overview.isEmpty, "\(topic.id) has no overview")
        }
    }

    @Test func guidesAndAPISectionsAreBothPopulated() {
        #expect(!DocCatalog.guides.isEmpty)
        #expect(!DocCatalog.api.isEmpty)
        #expect(DocCatalog.guides.allSatisfy { $0.kind == .guide })
        #expect(DocCatalog.api.allSatisfy { $0.kind == .api })
    }

    @Test func rubyLinkNamesAreUnique() {
        let names = RubyDocLink.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test(arguments: RubyDocLink.all)
    func rubyLinkIsHTTPSOnAKnownDocsHost(_ link: RubyDocLink) {
        let allowedHosts: Set = ["docs.ruby-lang.org", "ruby.github.io", "sparklemotion.github.io"]
        #expect(link.url.scheme == "https")
        #expect(allowedHosts.contains(link.url.host() ?? ""), "\(link.url)")
        #expect(!link.summary.isEmpty)
    }

    @Test func pathLinksResolveUnderTheRuby34Docs() {
        let link = RubyDocLink(name: "Net::HTTP", summary: "", path: "Net/HTTP.html")
        #expect(link.url.absoluteString == "https://docs.ruby-lang.org/en/3.4/Net/HTTP.html")
    }

    @Test func searchMatchesTitleOrSummaryIgnoringCase() {
        #expect(DocumentationView.matches("", title: "Gems", summary: "x"))
        #expect(DocumentationView.matches("  ", title: "Gems", summary: "x"))
        #expect(DocumentationView.matches("clip", title: "Device::Clipboard", summary: "x"))
        #expect(DocumentationView.matches("JSON", title: "Output", summary: "Return text or json"))
        #expect(!DocumentationView.matches("sqlite", title: "Input", summary: "ARGV"))
    }
}
