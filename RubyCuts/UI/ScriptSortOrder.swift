import Foundation

/// How ``ScriptLibrary/scripts`` are ordered in the list. Persisted across
/// launches (see ``ScriptLibrary/sortOrder``), so it's `String`-backed rather
/// than an `Int` enum: a raw value that survives a future case reorder.
enum ScriptSortOrder: String, CaseIterable, Identifiable {
    /// Alphabetical by display name. The default, and ``ScriptStore/list()``'s
    /// own sort, so this order needs no re-sorting on top of what the store
    /// already returns.
    case name

    /// Newest ``Script/modifiedAt`` first. A script with no readable date
    /// sorts last, since there's nothing to compare it against; ties (both
    /// dates equal, or both `nil`) fall back to name so the order is total
    /// and stable rather than depending on filesystem enumeration order.
    case dateModified

    nonisolated var id: String { rawValue }

    /// The label shown in the sort menu.
    var displayName: String {
        switch self {
        case .name: return "Name"
        case .dateModified: return "Date Modified"
        }
    }
}
