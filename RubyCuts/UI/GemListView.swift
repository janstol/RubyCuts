import SwiftUI

/// The gems sheet: an install form (name + optional version requirement) and
/// the list of installed gems, with delete. Reached from ``ScriptListView``
/// as a sheet, not a `navigationDestination` -- keeps gems out of the script
/// navigation path, matching the Phase 7 plan.
struct GemListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var library: GemLibrary
    @State private var gemName = ""
    @State private var gemRequirement = ""

    init(library: GemLibrary = GemLibrary()) {
        // `_library = State(initialValue:)` lets previews and tests inject a
        // VM seeded against a temp-dir store, matching `ScriptListView`.
        _library = State(initialValue: library)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Gems")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        // Without an explicit frame, a `.sheet` on macOS can size itself down
        // to fit almost nothing (unlike iOS, which gives a sheet a sane
        // default size), leaving the List invisible. `ScriptListPreview`'s
        // frame only covered the `#Preview`; the real sheet needs its own.
        .frame(minWidth: 400, minHeight: 300)
        .task {
            library.refresh()
        }
        .alert(
            "Error",
            isPresented: .init(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    private var content: some View {
        List {
            Section("Install a Gem") {
                TextField("Name (e.g. httparty)", text: $gemName)
                    .autocorrectionDisabled()
                TextField("Version (optional, e.g. ~> 1.0)", text: $gemRequirement)
                    .autocorrectionDisabled()
                Button {
                    installTapped()
                } label: {
                    if library.isInstalling {
                        ProgressView()
                    } else {
                        Text("Install")
                    }
                }
                .disabled(
                    library.isInstalling
                        || gemName.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }

            installedSection
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        if library.gems.isEmpty {
            Section {
                ContentUnavailableView(
                    "No Gems Installed",
                    systemImage: "shippingbox",
                    description: Text("Install a pure-Ruby gem above to use it from a script.")
                )
            }
        } else {
            Section("Installed") {
                ForEach(library.gems) { gem in
                    VStack(alignment: .leading) {
                        Text(gem.name)
                        Text(gem.version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            library.delete(gem)
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        library.delete(library.gems[index])
                    }
                }
            }
        }
    }

    private func installTapped() {
        let name = gemName.trimmingCharacters(in: .whitespaces)
        let requirement = gemRequirement
        Task {
            await library.install(name: name, requirement: requirement)
            gemName = ""
            gemRequirement = ""
        }
    }
}

#Preview {
    GemListPreview()
}

/// Backing view for ``GemListView``'s `#Preview`. Extracted into its own
/// type, mirroring ``ScriptListPreview``: side-effecting temp-dir setup
/// lives in this helper's `init` so the `#Preview` closure stays a plain
/// `ViewBuilder`. No network calls -- the preview seeds ``GemStore``
/// directly with already-"installed" directories, never through
/// ``GemInstaller``.
private struct GemListPreview: View {
    @State private var library: GemLibrary

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsPreview-\(UUID().uuidString)")
        let store = GemStore(directoryURL: dir)
        _ = try? store.ensureDirectory()
        for (name, version) in [("httparty", "0.21.0"), ("csv", "3.2.8")] {
            let gemLibDir = store.destinationURL(name: name, version: version)
                .appending(component: "lib")
            try? FileManager.default.createDirectory(
                at: gemLibDir, withIntermediateDirectories: true
            )
        }
        let library = GemLibrary(store: store, installer: GemInstaller(store: store))
        library.refresh()
        _library = State(initialValue: library)
    }

    var body: some View {
        GemListView(library: library)
            .frame(minWidth: 400, minHeight: 400)
    }
}
