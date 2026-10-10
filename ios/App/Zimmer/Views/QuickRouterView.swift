import SwiftUI
import ZimmerKit

/// Start work from a sentence. Zimmer's Quick Router reads the request, picks the agent
/// root and starts the session — the same flow as the web UI's bubble and the browser
/// extension, recorded as `ios_app`.
struct QuickRouterView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var isStarting = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Say what you want done. Zimmer picks where it runs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("e.g. Rotate the staging deploy key", text: $prompt, axis: .vertical)
                    .lineLimit(4...10)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .focused($focused)
                    .accessibilityIdentifier("quickrouter.field")
                if let error = app.error { ErrorBanner(error: error) }
                Spacer()
            }
            .padding()
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isStarting ? "Starting…" : "Start") {
                        Task {
                            isStarting = true
                            _ = await app.startQuickRouter(prompt)
                            isStarting = false
                        }
                    }
                    .disabled(isStarting || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("quickrouter.start")
                }
            }
            .onAppear { focused = true }
        }
    }
}
