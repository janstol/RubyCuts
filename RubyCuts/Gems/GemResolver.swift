import Foundation

/// One gem this resolution decided to install: the exact version chosen, and
/// where to download it from. Order in a resolution's result array is
/// dependency-discovery order (breadth-first), not install order -- it
/// carries no contract, since `$LOAD_PATH` resolves `require` by name
/// regardless of load order.
///
/// Opted out of the app target's MainActor-by-default isolation, matching
/// ``GemVersion``: a pure value type with no actor-coupled state, so every
/// member is `nonisolated` and usable from any context, including the
/// nonisolated test target's ``GemResolverTests``.
struct ResolvedGem: Sendable, Equatable {
    nonisolated let name: String
    nonisolated let version: GemVersion
    nonisolated let downloadURL: URL
    nonisolated let sha256: String

    /// VoiceOver phrasing for one "Ready to Install" row, e.g. `"httparty,
    /// version 0.22.0"`. Lives here rather than on `GemListView`'s
    /// `GemPlanSection` -- that's a `private struct`, and this composition
    /// needs to be testable without rendering a view. Deliberately doesn't
    /// include the requested/dependency tag: that's context only
    /// `GemPlanSection` has (its `requested` gem name), so the view appends
    /// it to this description instead.
    nonisolated var accessibilityDescription: String {
        "\(name), version \(version.raw)"
    }
}

/// An error raised while resolving a gem's runtime dependency graph.
enum GemResolverError: Error, Sendable, Equatable {
    /// No published, non-prerelease, `platform: "ruby"` version of `gem`
    /// satisfies `requirement`.
    case noVersionSatisfies(gem: String, requirement: String)

    /// Two different dependents need incompatible versions of `gem`. Named
    /// after the resolver's no-backtracking design: this is the honest
    /// failure mode instead of a wrong install.
    case conflictingRequirements(gem: String, first: String, second: String)

    /// A dependency's `requirements` string (from the RubyGems API) didn't
    /// parse as a ``GemRequirement``.
    case unparsableRequirement(gem: String, requirement: String)
}

/// Breadth-first, no-backtracking resolver over a gem's runtime dependency
/// graph.
///
/// For each gem it needs, it picks the newest non-prerelease
/// `platform: "ruby"` version satisfying every constraint gathered by the
/// time that gem is reached, then recurses into that version's runtime
/// dependencies. There's no backtracking: if two dependents need versions of
/// the same gem that can't both be satisfied, that's
/// ``GemResolverError/conflictingRequirements(gem:first:second:)``, not a
/// search for a version that works for both. Real backtracking resolution is
/// Bundler's job -- naive is the right call for V1, since the failure mode
/// is an honest error message, not a wrong install.
struct GemResolver: Sendable {
    nonisolated let api: RubyGemsAPI

    /// Resolves `name` (optionally pinned by `requirement`) and every
    /// runtime dependency it transitively needs. `installed` is a snapshot
    /// of what's already on disk (name -> version); a gem already installed
    /// at a version satisfying every constraint gathered so far is skipped
    /// entirely -- neither downloaded again nor recursed into (its own
    /// dependencies are assumed already satisfied from when it was
    /// installed).
    func resolve(
        name: String,
        requirement: GemRequirement?,
        installed: [String: GemVersion]
    ) async throws -> [ResolvedGem] {
        var chosen: [String: (version: GemVersion, requirement: GemRequirement?)] = [:]
        var plan: [ResolvedGem] = []
        var queue: [(name: String, requirement: GemRequirement?)] = [(name, requirement)]

        while !queue.isEmpty {
            let (gemName, gemRequirement) = queue.removeFirst()

            if let existing = chosen[gemName] {
                if let gemRequirement, !gemRequirement.satisfied(by: existing.version) {
                    throw GemResolverError.conflictingRequirements(
                        gem: gemName,
                        first: existing.requirement?.description ?? "(any)",
                        second: gemRequirement.description
                    )
                }
                continue
            }

            if let installedVersion = installed[gemName],
                gemRequirement?.satisfied(by: installedVersion) ?? true
            {
                chosen[gemName] = (installedVersion, gemRequirement)
                continue
            }

            let selected = try await selectVersion(for: gemName, requirement: gemRequirement)
            let details = try await api.versionDetails(ofGem: gemName, version: selected.raw)

            chosen[gemName] = (selected, gemRequirement)
            plan.append(
                ResolvedGem(
                    name: gemName, version: selected, downloadURL: details.gemUri,
                    sha256: details.sha
                )
            )

            for dependency in details.dependencies.runtime {
                guard let dependencyRequirement = GemRequirement(dependency.requirements) else {
                    throw GemResolverError.unparsableRequirement(
                        gem: dependency.name, requirement: dependency.requirements
                    )
                }
                queue.append((dependency.name, dependencyRequirement))
            }
        }

        return plan
    }

    /// Picks the newest non-prerelease `platform: "ruby"` version of `name`
    /// satisfying `requirement` (or the newest such version at all, if
    /// `requirement` is `nil`).
    private func selectVersion(
        for name: String, requirement: GemRequirement?
    ) async throws -> GemVersion {
        let versions = try await api.versions(ofGem: name)
        let candidates =
            versions
            .filter { $0.platform == "ruby" && !$0.prerelease }
            .compactMap { GemVersion($0.number) }
            .sorted(by: >)
        guard let selected = candidates.first(where: { requirement?.satisfied(by: $0) ?? true })
        else {
            throw GemResolverError.noVersionSatisfies(
                gem: name, requirement: requirement?.description ?? "(any)"
            )
        }
        return selected
    }
}
