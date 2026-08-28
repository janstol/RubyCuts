import Foundation

@testable import RubyCuts

/// A scripted `RubyGemsAPI` stub -- version lists and version details are
/// pre-seeded per gem name, so tests exercise resolution entirely offline,
/// matching the project's "the live network path is proxied, not exercised"
/// convention (see `RubyRuntimeTests.requiresNetHTTPOverTLS`).
///
/// Shared by `GemResolverTests` and `GemLibraryTests` so a real
/// dependency-shaped catalog (httparty's, most notably) doesn't need
/// duplicating between them.
struct StubRubyGemsAPI: RubyGemsAPI {
    struct Version {
        let number: String
        let platform: String
        let prerelease: Bool
        let dependencies: [(name: String, requirements: String)]

        init(
            _ number: String,
            platform: String = "ruby",
            prerelease: Bool = false,
            dependencies: [(name: String, requirements: String)] = []
        ) {
            self.number = number
            self.platform = platform
            self.prerelease = prerelease
            self.dependencies = dependencies
        }
    }

    /// name -> every published version.
    let catalog: [String: [Version]]

    func versions(ofGem name: String) async throws -> [GemVersionInfo] {
        guard let versions = catalog[name] else {
            throw RubyGemsAPIError.gemNotFound(name)
        }
        return versions.map {
            GemVersionInfo(number: $0.number, platform: $0.platform, prerelease: $0.prerelease)
        }
    }

    func versionDetails(ofGem name: String, version: String) async throws -> GemVersionDetails {
        guard let match = catalog[name]?.first(where: { $0.number == version }) else {
            throw RubyGemsAPIError.gemNotFound(name)
        }
        let runtime = match.dependencies.map {
            GemDependencyInfo(name: $0.name, requirements: $0.requirements)
        }
        return GemVersionDetails(
            dependencies: GemDependencies(runtime: runtime),
            gemUri: URL(string: "https://rubygems.org/gems/\(name)-\(version).gem")!,
            sha: "sha-\(name)-\(version)"
        )
    }
}
