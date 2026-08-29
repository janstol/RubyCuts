import Foundation

// All four DTOs below are marked `nonisolated` at the type level (rather
// than per-member, like ``Script``/``GemVersion``): each also carries a
// compiler-synthesized `Decodable.init(from:)`, and a type-level modifier is
// what makes *that* synthesized initializer nonisolated too, not just the
// memberwise one -- these are constructed both by `JSONDecoder` inside
// `LiveRubyGemsAPI` and directly by a stub `RubyGemsAPI` in the nonisolated
// test target's `GemResolverTests`.

/// One entry from `GET /api/v1/versions/<name>.json` -- a version RubyGems
/// has published for a gem, across every platform build and including
/// prereleases. Callers filter to `platform == "ruby"` and
/// `prerelease == false` themselves (``GemResolver`` does) rather than this
/// type doing it, so a caller that genuinely wants the raw list still can.
nonisolated struct GemVersionInfo: Decodable, Sendable {
    let number: String
    let platform: String
    let prerelease: Bool
}

/// One runtime dependency listed in a gem version's
/// `/api/v2/rubygems/.../versions/...json` response.
nonisolated struct GemDependencyInfo: Decodable, Sendable {
    let name: String
    let requirements: String
}

/// The `dependencies` envelope in the v2 response. `runtime` is the only
/// list this slice resolves -- `development` dependencies are never needed
/// to `require` the gem, only to build/test it.
nonisolated struct GemDependencies: Decodable, Sendable {
    let runtime: [GemDependencyInfo]
}

/// `GET /api/v2/rubygems/<name>/versions/<version>.json` -- everything
/// needed to download, verify, and recurse into one specific gem version.
nonisolated struct GemVersionDetails: Decodable, Sendable {
    let dependencies: GemDependencies
    let gemUri: URL
    let sha: String

    private enum CodingKeys: String, CodingKey {
        case dependencies
        case gemUri = "gem_uri"
        case sha
    }
}

/// One entry from `GET /api/v1/search.json` -- a gem matching a free-text
/// query, most relevant first per rubygems.org's own ranking. Only the
/// fields the Results section shows are decoded; the response carries more
/// (e.g. `platform`) that this slice has no use for.
nonisolated struct GemSearchResult: Decodable, Sendable, Equatable, Identifiable {
    let name: String
    let version: String
    let info: String
    let downloads: Int
    var id: String { name }
}

/// An error surfaced while talking to rubygems.org.
enum RubyGemsAPIError: Error, Sendable {
    /// The API returned 404 for this gem name -- it doesn't exist on
    /// rubygems.org (or was yanked entirely).
    case gemNotFound(String)

    /// A non-2xx, non-404 HTTP status.
    case httpError(status: Int)

    /// The response body didn't match the expected JSON shape.
    case decodingFailed(String)

    /// The response wasn't an HTTP response at all.
    case invalidResponse
}

/// Talks to rubygems.org's public API: candidate versions for a gem name,
/// and the runtime-dependency + download details for one specific version.
///
/// A protocol so ``GemResolver`` and ``GemInstaller`` can be driven by a
/// stub in tests and stay offline -- matching the existing convention where
/// the live network path is proxied, not exercised, in the test suite (see
/// `RubyRuntimeTests.requiresNetHTTPOverTLS`).
protocol RubyGemsAPI: Sendable {
    /// Every version RubyGems has published for `name`.
    func versions(ofGem name: String) async throws -> [GemVersionInfo]

    /// Runtime dependencies, download URL, and SHA-256 checksum for one
    /// exact `name`/`version`.
    func versionDetails(ofGem name: String, version: String) async throws -> GemVersionDetails

    /// Gems on rubygems.org matching a free-text `query`, most relevant
    /// first.
    func search(query: String) async throws -> [GemSearchResult]
}

/// The live implementation, backed by `URLSession`.
struct LiveRubyGemsAPI: RubyGemsAPI {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func versions(ofGem name: String) async throws -> [GemVersionInfo] {
        let url = URL(
            string: "https://rubygems.org/api/v1/versions/\(Self.encodedPathComponent(name)).json")!
        let (data, response) = try await session.data(from: url)
        try Self.checkHTTPStatus(response, gemName: name)
        do {
            return try JSONDecoder().decode([GemVersionInfo].self, from: data)
        } catch {
            throw RubyGemsAPIError.decodingFailed("\(error)")
        }
    }

    func versionDetails(ofGem name: String, version: String) async throws -> GemVersionDetails {
        let url = URL(
            string: "https://rubygems.org/api/v2/rubygems/\(Self.encodedPathComponent(name))"
                + "/versions/\(Self.encodedPathComponent(version)).json"
        )!
        let (data, response) = try await session.data(from: url)
        try Self.checkHTTPStatus(response, gemName: name)
        do {
            return try JSONDecoder().decode(GemVersionDetails.self, from: data)
        } catch {
            throw RubyGemsAPIError.decodingFailed("\(error)")
        }
    }

    func search(query: String) async throws -> [GemSearchResult] {
        var components = URLComponents(string: "https://rubygems.org/api/v1/search.json")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: "1"),
        ]
        let (data, response) = try await session.data(from: components.url!)
        try Self.checkHTTPStatus(response, gemName: query)
        do {
            return try JSONDecoder().decode([GemSearchResult].self, from: data)
        } catch {
            throw RubyGemsAPIError.decodingFailed("\(error)")
        }
    }

    private static func encodedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func checkHTTPStatus(_ response: URLResponse, gemName: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RubyGemsAPIError.invalidResponse
        }
        if http.statusCode == 404 {
            throw RubyGemsAPIError.gemNotFound(gemName)
        }
        guard (200...299).contains(http.statusCode) else {
            throw RubyGemsAPIError.httpError(status: http.statusCode)
        }
    }
}
