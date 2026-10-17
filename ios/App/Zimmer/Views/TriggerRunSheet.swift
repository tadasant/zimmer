import SwiftUI
import ZimmerKit

/// The web page's Run Trigger Manually panel, as a sheet: a field for each `{{variable}}`
/// the prompt template names, each optional, then Run. A template with no variables is
/// invoked from a confirmation instead, so this is only shown when there is something to fill.
struct TriggerRunSheet: View {
    let trigger: TriggerSummary
    let run: ([String: String]) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var running = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(trigger.promptVariables, id: \.self) { variable in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: "{{\(variable)}}").font(Theme.mono).foregroundStyle(Theme.inkSoft)
                            TextField(TriggerSummary.placeholder(for: variable), text: binding(variable), axis: variable == "text" ? .vertical : .horizontal)
                                .lineLimit(variable == "text" ? 2 ... 6 : 1 ... 1)
                                .font(.subheadline)
                                .foregroundStyle(Theme.ink)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("trigger.run.\(variable)")
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Variables").themeLabel()
                } footer: {
                    Text("This prompt template uses variables that are normally filled from external events. You can optionally provide values, or leave them blank; {{time}} and {{date}} fill themselves.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkMute)
                }
                .themeRows()
                if let template = trigger.promptTemplate {
                    Section {
                        Text(template).font(Theme.mono).foregroundStyle(Theme.inkSoft).textSelection(.enabled)
                    } header: {
                        Text("Prompt template").themeLabel()
                    }
                    .themeRows()
                }
            }
            .themeGround()
            .navigationTitle("Run \(trigger.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(running ? "Running…" : "Run") {
                        running = true
                        Task {
                            await run(values)
                            dismiss()
                        }
                    }
                    .disabled(running)
                    .accessibilityIdentifier("trigger.run.submit")
                }
            }
            .interactiveDismissDisabled(running)
            .accessibilityIdentifier("trigger.run.sheet")
        }
        .tint(Theme.accent)
    }

    private func binding(_ variable: String) -> Binding<String> {
        Binding(get: { values[variable] ?? "" }, set: { values[variable] = $0 })
    }
}
