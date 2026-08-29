import Foundation
import Testing

@testable import RubyCuts

/// Decoding coverage for the DTOs in `RubyGemsAPI.swift`. Only
/// ``GemSearchResult`` has a dedicated test here -- the others are exercised
/// indirectly through `GemResolverTests` and `GemLibraryTests` via
/// `StubRubyGemsAPI`, but search is decoded straight from a live-shaped
/// response with no stub in between, so it gets its own check against the
/// real field names and extra keys rubygems.org actually sends.
@Suite
struct RubyGemsAPITests {
    /// A trimmed copy of one entry from a real
    /// `GET /api/v1/search.json?query=httparty` response, extra keys (that
    /// ``GemSearchResult`` doesn't decode) left in on purpose.
    private static let searchResponseJSON = """
        [
          {
            "name": "httparty",
            "downloads": 123456789,
            "version": "0.22.0",
            "version_downloads": 987654,
            "platform": "ruby",
            "authors": "Michael Bleigh, John Nunemaker",
            "info": "Makes http fun again!",
            "licenses": ["MIT"],
            "metadata": {},
            "yanked": false,
            "sha": "deadbeef"
          }
        ]
        """

    @Test func gemSearchResultDecodesTheFourFieldsItUsesAndIgnoresTheRest() throws {
        let data = try #require(Self.searchResponseJSON.data(using: .utf8))

        let results = try JSONDecoder().decode([GemSearchResult].self, from: data)

        let result = try #require(results.first)
        #expect(result.name == "httparty")
        #expect(result.version == "0.22.0")
        #expect(result.info == "Makes http fun again!")
        #expect(result.downloads == 123_456_789)
    }
}
