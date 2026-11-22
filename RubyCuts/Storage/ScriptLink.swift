import Foundation

/// The `rubycuts://script?name=hello.rb` link that opens a script in the app. The widget attaches it so tapping opens the script it shows; the app parses it in `onOpenURL`.
///
/// The script is named by file name, like ``ScriptEntity``, because that resolves the same way whichever store (local or iCloud) is current.
nonisolated enum ScriptLink {
    /// The URL scheme, registered in `Config/RubyCuts-Info.plist`.
    static let scheme = "rubycuts"
    private static let host = "script"
    private static let nameItem = "name"

    /// The link that opens the script with this file name, e.g. `"hello.rb"`.
    static func url(forFileName fileName: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: nameItem, value: fileName)]
        guard let url = components.url else {
            preconditionFailure("URLComponents rejected a script link for \(fileName)")
        }
        return url
    }

    /// The file name a script link points at, or `nil` if `url` isn't a script link or names something other than a plain file name (one with a path in it can't have come from ``url(forFileName:)``, so it's never trusted).
    static func fileName(from url: URL) -> String? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == scheme,
            components.host?.lowercased() == host,
            let name = components.queryItems?.first(where: { $0.name == nameItem })?.value,
            !name.isEmpty, name != ".", name != "..",
            (name as NSString).lastPathComponent == name
        else {
            return nil
        }
        return name
    }
}
