import SwiftUI

/// A third-party component compiled into the app, with the license text it
/// ships under. The texts live in `RubyCuts/Acknowledgements/` and are copied
/// flat into the app bundle, hence the `License-` prefix keeping the names
/// unique.
nonisolated struct Acknowledgement: Identifiable, Equatable {
    /// The component's name as shown in the list.
    let name: String

    /// A short license label, e.g. `"MIT"`.
    let license: String

    /// The bundled `.txt` resource holding the full license text, without extension.
    let resourceName: String

    var id: String { name }

    /// Everything statically linked into `libruby-static.a` by `scripts/build-cruby.rb`.
    static let all: [Acknowledgement] = [
        Acknowledgement(
            name: "Ruby", license: "Ruby License / BSD-2-Clause", resourceName: "License-Ruby"),
        Acknowledgement(name: "OpenSSL", license: "Apache 2.0", resourceName: "License-OpenSSL"),
        Acknowledgement(name: "libyaml", license: "MIT", resourceName: "License-libyaml"),
        Acknowledgement(name: "SQLite", license: "Public Domain", resourceName: "License-SQLite"),
        Acknowledgement(
            name: "sqlite3-ruby", license: "BSD-3-Clause", resourceName: "License-sqlite3-ruby"),
    ]

    /// The full license text from `bundle`, or `nil` if the resource is missing.
    func licenseText(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "txt") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Lists the open-source components RubyCuts ships, each pushing to its
/// license text. Hosted inside the settings sheet's `NavigationStack`.
struct AcknowledgementsView: View {
    var body: some View {
        List(Acknowledgement.all) { acknowledgement in
            NavigationLink {
                LicenseTextView(acknowledgement: acknowledgement)
            } label: {
                LabeledContent(acknowledgement.name, value: acknowledgement.license)
            }
        }
        .navigationTitle("Acknowledgements")
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// One component's full license text, selectable so it can be copied.
private struct LicenseTextView: View {
    let acknowledgement: Acknowledgement

    var body: some View {
        ScrollView {
            Text(acknowledgement.licenseText() ?? "License text unavailable.")
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(acknowledgement.name)
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    NavigationStack {
        AcknowledgementsView()
    }
}
