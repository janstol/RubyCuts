import SwiftUI

/// A documentation detail page, pushed from ``DocumentationView``'s index:
/// the topic's overview, its members, copyable examples and notes.
struct DocTopicView: View {
    let topic: DocTopic

    var body: some View {
        List {
            Section {
                Text(topic.overview)
            }
            if !topic.members.isEmpty {
                Section(topic.kind == .api ? "Methods" : "Reference") {
                    ForEach(topic.members, id: \.self) { member in
                        MemberRow(member: member)
                    }
                }
            }
            if !topic.examples.isEmpty {
                Section("Examples") {
                    ForEach(topic.examples, id: \.self) { example in
                        DocExampleView(example: example)
                    }
                }
            }
            if !topic.notes.isEmpty {
                Section("Notes") {
                    ForEach(topic.notes, id: \.self) { note in
                        Text(note)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(topic.title)
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// A member entry: a monospaced signature above its prose explanation.
private struct MemberRow: View {
    let member: DocMember

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(member.signature)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text(member.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// A code example: its title and Copy button above the syntax-highlighted
/// code, which scrolls horizontally rather than wrapping.
private struct DocExampleView: View {
    let example: DocExample

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(example.title)
                    .font(.headline)
                Spacer()
                Button {
                    ClipboardCapability.setText(example.code)
                    didCopy = true
                } label: {
                    Label(
                        didCopy ? "Copied" : "Copy",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .font(.callout)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
                .help("Copy")
                .accessibilityHint("Copies the example code")
            }
            ScrollView(.horizontal) {
                Text(RubySyntaxHighlighting.highlighted(example.code))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
        .padding(.vertical, 4)
        // Without this, the row separator lines up with the Copy label's
        // text instead of the row's leading edge.
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}

#Preview("Guide") {
    NavigationStack {
        DocTopicView(topic: DocCatalog.input)
    }
}

#Preview("API") {
    NavigationStack {
        DocTopicView(topic: DocCatalog.clipboard)
    }
}
