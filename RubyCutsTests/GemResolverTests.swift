import Foundation
@testable import RubyCuts
import Testing

// `StubRubyGemsAPI` lives in `StubRubyGemsAPI.swift`, shared with
// `GemLibraryTests`.

@Suite
struct GemResolverTests {

    /// httparty's real runtime dependency shape (per the Phase 7 plan's PRD
    /// success metric): resolving httparty must pull in csv, mini_mime, and
    /// multi_xml.
    private static let httpartyCatalog: [String: [StubRubyGemsAPI.Version]] = [
        "httparty": [
            StubRubyGemsAPI.Version(
                "0.22.0",
                dependencies: [
                    ("csv", "~> 3.0"),
                    ("mini_mime", ">= 1.0.0"),
                    ("multi_xml", ">= 0.5.2"),
                ]
            )
        ],
        "csv": [StubRubyGemsAPI.Version("3.3.0")],
        "mini_mime": [StubRubyGemsAPI.Version("1.1.5")],
        "multi_xml": [StubRubyGemsAPI.Version("0.7.1")],
    ]

    @Test func resolvesHttpartyAndItsRuntimeDependencies() async throws {
        let resolver = GemResolver(api: StubRubyGemsAPI(catalog: Self.httpartyCatalog))

        let plan = try await resolver.resolve(name: "httparty", requirement: nil, installed: [:])

        let names = Set(plan.map(\.name))
        #expect(names == ["httparty", "csv", "mini_mime", "multi_xml"])
        let httparty = try #require(plan.first { $0.name == "httparty" })
        #expect(httparty.version.raw == "0.22.0")
    }

    @Test func alreadyInstalledGemAtASatisfyingVersionIsSkipped() async throws {
        let resolver = GemResolver(api: StubRubyGemsAPI(catalog: Self.httpartyCatalog))
        let installed = ["csv": try #require(GemVersion("3.3.0"))]

        let plan = try await resolver.resolve(
            name: "httparty", requirement: nil, installed: installed
        )

        let names = Set(plan.map(\.name))
        #expect(!names.contains("csv"))
        #expect(names.contains("httparty"))
        #expect(names.contains("mini_mime"))
        #expect(names.contains("multi_xml"))
    }

    @Test func installedAtANonSatisfyingVersionIsStillResolved() async throws {
        let resolver = GemResolver(api: StubRubyGemsAPI(catalog: Self.httpartyCatalog))
        // 2.0.0 doesn't satisfy httparty's "~> 3.0" requirement on csv, so the
        // resolver must not skip it just because some version is installed.
        let installed = ["csv": try #require(GemVersion("2.0.0"))]

        let plan = try await resolver.resolve(
            name: "httparty", requirement: nil, installed: installed
        )

        #expect(plan.contains { $0.name == "csv" })
    }

    @Test func nonRubyPlatformVersionsAreExcluded() async throws {
        let catalog: [String: [StubRubyGemsAPI.Version]] = [
            "nokogiri": [
                StubRubyGemsAPI.Version("1.15.0", platform: "arm64-darwin"),
                StubRubyGemsAPI.Version("1.14.0", platform: "ruby"),
            ]
        ]
        let resolver = GemResolver(api: StubRubyGemsAPI(catalog: catalog))

        let plan = try await resolver.resolve(name: "nokogiri", requirement: nil, installed: [:])

        #expect(plan.first?.version.raw == "1.14.0")
    }

    @Test func prereleaseVersionsAreExcluded() async throws {
        let catalog: [String: [StubRubyGemsAPI.Version]] = [
            "foo": [
                StubRubyGemsAPI.Version("2.0.0.pre", prerelease: true),
                StubRubyGemsAPI.Version("1.9.0"),
            ]
        ]
        let resolver = GemResolver(api: StubRubyGemsAPI(catalog: catalog))

        let plan = try await resolver.resolve(name: "foo", requirement: nil, installed: [:])

        #expect(plan.first?.version.raw == "1.9.0")
    }

    @Test func noVersionSatisfyingTheRequirementProducesANamedError() async throws {
        let catalog: [String: [StubRubyGemsAPI.Version]] = [
            "lonely": [StubRubyGemsAPI.Version("1.0.0")]
        ]
        let resolver = GemResolver(api: StubRubyGemsAPI(catalog: catalog))
        let requirement = try #require(GemRequirement(">= 2.0.0"))

        do {
            _ = try await resolver.resolve(
                name: "lonely", requirement: requirement, installed: [:]
            )
            Issue.record("expected resolve to throw when no version satisfies")
        } catch GemResolverError.noVersionSatisfies(let gem, _) {
            #expect(gem == "lonely")
        } catch {
            Issue.record("expected GemResolverError.noVersionSatisfies, got \(error)")
        }
    }

    @Test func aDependencyAlreadySatisfiedByABundledGemIsNeverFetched() async throws {
        // Mirrors what GemInstaller.bundledVersionsByName() actually does
        // since Phase 7's sqlite3 slice: pass every BundledGem as `bundled`
        // before resolving, so a gem that depends on sqlite3 resolves as
        // already-satisfied. `catalog` deliberately has no "sqlite3" entry:
        // if the resolver ever tried to fetch it (versions or details)
        // despite the seed, StubRubyGemsAPI would raise `gemNotFound` and
        // this test would fail, not silently pass.
        let catalog: [String: [StubRubyGemsAPI.Version]] = [
            "needs-sqlite3": [
                StubRubyGemsAPI.Version("1.0.0", dependencies: [("sqlite3", ">= 0")])
            ]
        ]
        let resolver = GemResolver(api: StubRubyGemsAPI(catalog: catalog))
        let bundled = ["sqlite3": try #require(GemVersion("2.9.6"))]

        let plan = try await resolver.resolve(
            name: "needs-sqlite3", requirement: nil, installed: [:], bundled: bundled
        )

        let names = Set(plan.map(\.name))
        #expect(names == ["needs-sqlite3"])
        #expect(!names.contains("sqlite3"))
    }

    @Test func anInstalledGemWithAMissingDependencyResolvesToJustThatDependency() async throws {
        // httparty is on disk but csv isn't: deleted since, or an earlier
        // install failed before csv landed. Reinstalling httparty must still
        // walk its dependencies and plan csv, or the gem stays unusable.
        let resolver = GemResolver(api: StubRubyGemsAPI(catalog: Self.httpartyCatalog))
        let installed = [
            "httparty": try #require(GemVersion("0.22.0")),
            "mini_mime": try #require(GemVersion("1.1.5")),
            "multi_xml": try #require(GemVersion("0.7.1")),
        ]

        let plan = try await resolver.resolve(
            name: "httparty", requirement: nil, installed: installed
        )

        #expect(plan.map(\.name) == ["csv"])
    }

    @Test func aFullyInstalledGemResolvesToAnEmptyPlan() async throws {
        let resolver = GemResolver(api: StubRubyGemsAPI(catalog: Self.httpartyCatalog))
        let installed = [
            "httparty": try #require(GemVersion("0.22.0")),
            "csv": try #require(GemVersion("3.3.0")),
            "mini_mime": try #require(GemVersion("1.1.5")),
            "multi_xml": try #require(GemVersion("0.7.1")),
        ]

        let plan = try await resolver.resolve(
            name: "httparty", requirement: nil, installed: installed
        )

        #expect(plan.isEmpty)
    }

    @Test func conflictingRequirementsProduceANamedError() async throws {
        // root depends on both a and b, which each pin a different, mutually
        // exclusive version of the same shared leaf gem, a genuine conflict
        // the naive, no-backtracking resolver can't paper over.
        let catalog: [String: [StubRubyGemsAPI.Version]] = [
            "root": [
                StubRubyGemsAPI.Version("1.0.0", dependencies: [("a", ">= 0"), ("b", ">= 0")])
            ],
            "a": [StubRubyGemsAPI.Version("1.0.0", dependencies: [("shared", "= 1.0.0")])],
            "b": [StubRubyGemsAPI.Version("1.0.0", dependencies: [("shared", "= 2.0.0")])],
            "shared": [StubRubyGemsAPI.Version("1.0.0"), StubRubyGemsAPI.Version("2.0.0")],
        ]
        let resolver = GemResolver(api: StubRubyGemsAPI(catalog: catalog))

        do {
            _ = try await resolver.resolve(name: "root", requirement: nil, installed: [:])
            Issue.record("expected resolve to throw on conflicting requirements")
        } catch GemResolverError.conflictingRequirements(let gem, _, _) {
            #expect(gem == "shared")
        } catch {
            Issue.record("expected GemResolverError.conflictingRequirements, got \(error)")
        }
    }

    @Test func resolvedGemAccessibilityDescriptionCombinesNameAndVersion() throws {
        let gem = ResolvedGem(
            name: "httparty", version: try #require(GemVersion("0.22.0")),
            downloadURL: URL(string: "https://rubygems.org/gems/httparty-0.22.0.gem")!,
            sha256: "sha-httparty"
        )

        let description = gem.accessibilityDescription

        #expect(description.contains("httparty"))
        #expect(description.contains("0.22.0"))
    }
}
