import SwiftUI

/// What deleting one installed gem would affect, from
/// ``GemLibrary/deletion(of:)``: the installed gems that need it (they break
/// without it) and the dependencies it leaves unused (offered for removal
/// too). Carries the confirmation dialog's wording, so the macOS pane and the
/// iOS list say the same thing and the wording is testable without a view.
struct GemDeletion {
    let gem: InstalledGem

    /// Installed gems that list ``gem`` as a dependency.
    let dependents: [String]

    /// Installed dependencies nothing else would use once ``gem`` is gone.
    let orphans: [InstalledGem]

    var title: String { "Delete \(gem.name)?" }

    var message: String {
        var parts: [String] = []
        if !dependents.isEmpty {
            let needs = dependents.count == 1 ? "needs" : "need"
            let them = dependents.count == 1 ? "it" : "them"
            parts.append(
                "\(Self.list(dependents)) \(needs) \(gem.name). Scripts that require \(them) "
                    + "will fail until \(gem.name) is reinstalled.")
        }
        if !orphans.isEmpty {
            let were = orphans.count == 1 ? "was" : "were"
            let them = orphans.count == 1 ? "it" : "them"
            parts.append(
                "\(Self.list(orphans.map(\.name))) \(were) installed for \(gem.name), "
                    + "and nothing else uses \(them).")
        }
        if parts.isEmpty {
            parts.append("\"\(gem.name)\" will need to be reinstalled to use it again.")
        }
        return parts.joined(separator: " ")
    }

    /// The label for removing ``gem`` together with its ``orphans``.
    var deleteWithOrphansLabel: String {
        let noun = orphans.count == 1 ? "Dependency" : "Dependencies"
        return "Delete \(gem.name) and \(orphans.count) \(noun)"
    }

    private static func list(_ names: [String]) -> String {
        ListFormatter.localizedString(byJoining: names)
    }
}

extension View {
    /// The delete confirmation for installed gems, shared by
    /// ``GemSettingsMacPane`` and ``GemListView``: presented while
    /// `pending` is non-`nil`, worded from ``GemDeletion``, and offering
    /// "Delete X and N Dependencies" next to "Delete X Only" when the gem
    /// leaves dependencies unused. `onDeleted` runs after either delete.
    func gemDeleteConfirmation(
        _ pending: Binding<InstalledGem?>, library: GemLibrary, onDeleted: @escaping () -> Void = {}
    ) -> some View {
        modifier(GemDeleteConfirmation(pending: pending, library: library, onDeleted: onDeleted))
    }
}

private struct GemDeleteConfirmation: ViewModifier {
    @Binding var pending: InstalledGem?
    let library: GemLibrary
    let onDeleted: () -> Void

    func body(content: Content) -> some View {
        let deletion = pending.map(library.deletion(of:))
        content.confirmationDialog(
            deletion?.title ?? "",
            isPresented: .init(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletion
        ) { deletion in
            if deletion.orphans.isEmpty {
                Button("Delete \(deletion.gem.name)", role: .destructive) {
                    finish { library.delete(deletion.gem) }
                }
            } else {
                Button(deletion.deleteWithOrphansLabel, role: .destructive) {
                    finish { library.delete(deletion.gem, alongWith: deletion.orphans) }
                }
                Button("Delete \(deletion.gem.name) Only", role: .destructive) {
                    finish { library.delete(deletion.gem) }
                }
            }
            Button("Cancel", role: .cancel) {
                pending = nil
            }
        } message: { deletion in
            Text(deletion.message)
        }
    }

    private func finish(_ delete: () -> Void) {
        delete()
        pending = nil
        onDeleted()
    }
}
