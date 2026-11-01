import Foundation

/// Version details shown in the About section of the iOS settings sheet.
///
/// `nonisolated` to opt out of the app target's MainActor default: it's a
/// plain value read from an `Info.plist` dictionary, with nothing to protect.
nonisolated struct AppInfo: Equatable {
    /// The marketing version (`CFBundleShortVersionString`, from `MARKETING_VERSION`), e.g. `"1.0"`.
    let version: String

    /// The build number (`CFBundleVersion`, from `CURRENT_PROJECT_VERSION`), e.g. `"2"`.
    let build: String

    /// The embedded CRuby's version, e.g. `"3.4.9"`.
    let rubyVersion: String

    /// The app's own version and build, using the embedded runtime's Ruby version.
    static let current = AppInfo(
        infoDictionary: Bundle.main.infoDictionary ?? [:],
        rubyVersion: String(cString: rubycuts_ruby_version())
    )

    /// Reads ``version`` and ``build`` from `infoDictionary`, falling back to
    /// `"Unknown"` for a missing key so the About row never renders blank.
    init(infoDictionary: [String: Any], rubyVersion: String) {
        version = infoDictionary["CFBundleShortVersionString"] as? String ?? "Unknown"
        build = infoDictionary["CFBundleVersion"] as? String ?? "Unknown"
        self.rubyVersion = rubyVersion
    }

    // Literal URLs known valid at compile time, so the force unwraps can't fail.

    /// The public source repository, linked from the iOS About section and the macOS Help menu.
    static let sourceCodeURL = URL(string: "https://github.com/janstol/RubyCuts")!

    /// The privacy policy, linked from the iOS About section and the macOS Help menu. App Review requires it to be reachable inside the app on every platform.
    static let privacyPolicyURL = URL(string: "https://janstol.github.io/RubyCuts/privacy.html")!

    /// Version and build in the form iOS apps conventionally show, e.g. `"1.0 (2)"`.
    var versionAndBuild: String {
        "\(version) (\(build))"
    }
}
