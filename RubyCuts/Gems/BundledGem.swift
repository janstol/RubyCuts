import Foundation

/// A C-extension gem baked directly into the app binary at build time,
/// rather than downloaded through ``GemInstaller``. App Store W^X rules
/// mean a downloaded `.bundle` can never be `dlopen`ed on device, so a
/// C-extension gem can only ever ship this way. `sqlite3` is currently the
/// only one; see `scripts/build-cruby.rb`'s `SQLITE3_GEM_VERSION_PIN` and
/// `docs/embedding-cruby.md` for how its C sources land in
/// `libruby-static.a` and its Ruby-side `lib/` lands in
/// `Vendor/CRuby/stdlib/`.
///
/// `Sendable` and every member `nonisolated`, matching ``InstalledGem``: a
/// pure value type with no actor-coupled state.
struct BundledGem: Identifiable, Hashable, Sendable {
    /// The gem's name, e.g. `"sqlite3"`.
    nonisolated let name: String

    /// The version baked in: must match `SQLITE3_GEM_VERSION_PIN` in
    /// `scripts/build-cruby.rb`, the source of truth for the pin. Kept
    /// honest by `BundledGemTests.matchesTheVersionPinBakedIntoTheVM`, which
    /// reads `SQLite3::VERSION` back out of the running VM.
    nonisolated let version: String

    nonisolated var id: String { name }

    /// Every gem baked into this build. Currently just `sqlite3`.
    nonisolated static let all: [BundledGem] = [
        BundledGem(name: "sqlite3", version: "2.9.6")
    ]
}
