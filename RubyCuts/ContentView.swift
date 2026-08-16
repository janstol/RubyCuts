import SwiftUI

/// Placeholder root view, shown until script discovery and editing land.
struct ContentView: View {
    var body: some View {
        ContentUnavailableView(
            "No Scripts Yet",
            systemImage: "doc.text",
            description: Text("RubyCuts scripts will show up here.")
        )
    }
}

#Preview {
    ContentView()
}
