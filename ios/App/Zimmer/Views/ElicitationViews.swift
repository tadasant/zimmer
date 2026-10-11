import SwiftUI
import ZimmerKit

/// An MCP server's question, on the session it stopped: the web UI's "Action Approval
/// Required" banner. Tapping it opens the form.
struct PromptCard: View {
    let prompt: PendingElicitation
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Approval Needed").font(.subheadline.weight(.semibold))
                    if let tool = prompt.toolName {
                        Text(tool)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                Text(prompt.message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if let expiresAt = prompt.expiresAt {
                    Text("Expires \(expiresAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("prompt.\(prompt.id)")
    }
}

/// The prompt's form, with the protocol's three answers. Accept sends the fields; Decline
/// and Dismiss send none. A refusal stays on screen with the form intact.
struct ElicitationSheet: View {
    let prompt: PendingElicitation
    /// Sends the answer; returns why it was refused, or nil when it went through.
    let send: (ElicitationAnswer, String?) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [String: String] = [:]
    @State private var toggles: [String: Bool] = [:]
    @State private var sending: ElicitationAnswer?
    @State private var refusal: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(prompt.message).font(.body)
                    if let context = prompt.context, !context.isEmpty {
                        Text(context).font(.callout).foregroundStyle(.secondary).italic()
                    }
                } header: {
                    Text(prompt.toolName ?? "MCP server")
                }
                ForEach(prompt.form.fields) { field in
                    Section {
                        control(for: field)
                    } header: {
                        Text(field.required ? "\(field.title) (required)" : field.title)
                    } footer: {
                        if let detail = field.detail { Text(detail) }
                    }
                }
                if let refusal {
                    Section {
                        Label(refusal, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("prompt.refusal")
                    }
                }
                Section {
                    Button {
                        Task { await submit(.decline) }
                    } label: {
                        Label("Decline", systemImage: "xmark")
                    }
                    .accessibilityIdentifier("prompt.decline")
                    Button {
                        Task { await submit(.cancel) }
                    } label: {
                        Label("Dismiss Without Answering", systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("prompt.dismiss")
                } footer: {
                    Text("Dismiss tells the MCP server nobody decided, instead of leaving it waiting until the prompt expires.")
                }
            }
            .disabled(sending != nil)
            .navigationTitle("Approval Needed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit(.accept) }
                    } label: {
                        if sending == .accept { ProgressView() } else { Text("Accept").bold() }
                    }
                    .disabled(sending != nil)
                    .accessibilityIdentifier("prompt.accept")
                }
            }
        }
    }

    @ViewBuilder
    private func control(for field: ElicitationForm.Field) -> some View {
        switch field.kind {
        case .toggle:
            Toggle("Yes", isOn: Binding(get: { toggles[field.key] ?? false }, set: { toggles[field.key] = $0 }))
                .accessibilityIdentifier("prompt.field.\(field.key)")
        case let .choice(options):
            Picker(field.title, selection: Binding(get: { entries[field.key] ?? "" }, set: { entries[field.key] = $0 })) {
                Text("Choose…").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("prompt.field.\(field.key)")
        case let .number(integer):
            TextField(field.placeholder ?? (integer ? "Whole number" : "Number"), text: binding(field.key))
                .keyboardType(integer ? .numberPad : .decimalPad)
                .accessibilityIdentifier("prompt.field.\(field.key)")
        case .text:
            TextField(field.placeholder ?? "", text: binding(field.key), axis: .vertical)
                .accessibilityIdentifier("prompt.field.\(field.key)")
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { entries[key] ?? "" }, set: { entries[key] = $0 })
    }

    private func submit(_ answer: ElicitationAnswer) async {
        var content: String?
        if answer == .accept {
            do {
                content = try prompt.form.content(from: entries, toggles: toggles)
            } catch let error as ElicitationFormError {
                refusal = error.message
                return
            } catch {
                refusal = "This form could not be read."
                return
            }
        }
        sending = answer
        defer { sending = nil }
        if let reason = await send(answer, content) {
            refusal = reason
        } else {
            dismiss()
        }
    }
}
