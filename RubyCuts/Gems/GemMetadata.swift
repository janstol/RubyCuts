import Foundation

/// What RubyCuts records about an installed gem, beside its files: whether
/// the user asked for it or it came in as a dependency, and which gems it
/// needs. Stored as ``fileName`` in the gem's directory, outside `lib/`, so
/// it never ends up on `$LOAD_PATH`.
///
/// It's what lets the gem list say "Used by httparty", warn before deleting
/// a gem another one needs, and offer to remove the dependencies a deleted
/// gem leaves unused. ``GemInstaller`` writes it at install time from the
/// resolved plan; ``GemLibrary/backfillMetadata()`` fills it in once from
/// rubygems.org for gems installed before it existed.
nonisolated struct GemMetadata: Codable, Sendable, Equatable {
    /// The file name inside the gem's directory.
    static let fileName = ".rubycuts-gem.json"

    /// `true` when the user installed this gem by name, `false` when it was
    /// pulled in as another gem's dependency.
    var requested: Bool

    /// The names of the gem's runtime dependencies, as rubygems.org lists
    /// them. May name a bundled gem, which needs no install.
    var dependencies: [String]
}
