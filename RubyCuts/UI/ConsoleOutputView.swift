import SwiftUI

/// Displays a ``RunResult`` from ``RubyRuntime/run(_:)``: captured `STDOUT`,
/// `STDERR`, the last expression's value, and any error message. Shown in the
/// editor as a bottom panel after a Run.
///
/// Plain presentation over a value type -- no view model, because the result is
/// a snapshot held in `@State` by the editor, not observable list state. The
/// sections are stacked and each scrolls independently so a long `puts` dump
/// doesn't push the error off-screen.
struct ConsoleOutputView: View {
    let result: RunResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Console")
                    .font(.headline)
                Spacer()
                if result.hasError {
                    Label("Failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            if !result.stdout.isEmpty {
                section("Output", text: result.stdout)
            }
            if !result.stderr.isEmpty {
                section("Errors", text: result.stderr, tint: .red)
            }
            if let errorMessage = result.errorMessage {
                section("Error", text: errorMessage, tint: .red)
            }
            if !result.backtrace.isEmpty {
                section("Backtrace", text: result.backtrace.joined(separator: "\n"), tint: .red)
            }
            // The last expression's value is only meaningful on a clean run with
            // a non-empty result -- `puts`-only scripts end in `nil` (""), and a
            // raised script reports via `errorMessage` above.
            if !result.hasError && !result.result.isEmpty {
                section("Result", text: result.result, tint: .secondary)
            }
        }
        .padding(.horizontal)
        .padding(.bottom)
    }

    @ViewBuilder
    private func section(_ title: String, text: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(tint ?? .secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

#Preview {
    ConsoleOutputView(
        result: RunResult(
            stdout: "hello, world\n[1, 2, 3]",
            stderr: "warning: something",
            result: "nil",
            errorMessage: nil
        )
    )
    .frame(maxWidth: 400, maxHeight: 250)
}

#Preview {
    ConsoleOutputView(
        result: RunResult(
            stdout: "printed before crash",
            stderr: "",
            result: "",
            errorMessage: "undefined method 'foo' for nil (NoMethodError)",
            backtrace: [
                "rubycuts:3:in 'foo'",
                "rubycuts:1:in '<main>'",
            ]
        )
    )
    .frame(maxWidth: 400, maxHeight: 200)
}
