import SwiftUI
import ZimmerKit

/// The web UI's queued-messages panel: what is waiting for the turn in flight to end, in
/// delivery order. Each message can be sent now (ending the turn), edited or deleted;
/// *Manage* opens the whole queue to drag into a new order.
struct QueueCard: View {
    @ObservedObject var model: SessionDetailModel
    @State private var editing: QueuedMessage?
    @State private var managing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Queued messages (\(model.queue.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Manage") { managing = true }
                    .font(.caption)
                    .accessibilityIdentifier("queue.manage")
            }
            ForEach(model.queue) { message in
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: "\(message.position).")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(message.content)
                        .font(.subheadline)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("queue.message.\(message.id)")
                    Menu {
                        Button {
                            Task { await model.sendQueuedNow(message) }
                        } label: {
                            Label("Send Now", systemImage: "bolt.fill")
                        }
                        Button { editing = message } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) {
                            Task { await model.deleteQueued(message) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Queued message actions")
                    .accessibilityIdentifier("queue.actions.\(message.id)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.queue")
        .sheet(item: $editing) { message in
            QueuedMessageEditor(message: message) { text in
                await model.editQueued(message, content: text)
            }
        }
        .sheet(isPresented: $managing) { QueueManager(model: model) }
    }
}

/// The whole queue, in iOS's own list editing: drag a message to its new place, swipe one
/// away. Each drop is one `reorder` call with the new position.
private struct QueueManager: View {
    @ObservedObject var model: SessionDetailModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.queue) { message in
                    Text(message.content).lineLimit(3)
                }
                .onMove { source, destination in
                    guard let from = source.first else { return }
                    let message = model.queue[from]
                    // `destination` counts the slot before the move; positions count from 1.
                    let position = destination > from ? destination : destination + 1
                    Task { await model.moveQueued(message, to: position) }
                }
                .onDelete { offsets in
                    let doomed = offsets.map { model.queue[$0] }
                    Task { for message in doomed { await model.deleteQueued(message) } }
                }
            }
            .environment(\.editMode, .constant(.active))
            .overlay {
                if model.queue.isEmpty { ContentUnavailableView("Nothing queued", systemImage: "tray") }
            }
            .navigationTitle("Queued messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Rewrite one queued message before it is delivered.
private struct QueuedMessageEditor: View {
    let message: QueuedMessage
    let save: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .accessibilityIdentifier("queue.edit.text")
                .navigationTitle("Edit queued message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Saving…" : "Save") {
                            Task {
                                saving = true
                                let saved = await save(text.trimmingCharacters(in: .whitespacesAndNewlines))
                                saving = false
                                if saved { dismiss() }
                            }
                        }
                        .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("queue.edit.save")
                    }
                }
                .onAppear { text = message.content }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - The queue's calls

extension SessionDetailModel {
    func sendQueuedNow(_ message: QueuedMessage) async {
        await changeQueue("Sent now — the current turn ends.") { try await $0.sendQueuedNow(self.id, message: message.id) }
        await load()
    }

    func deleteQueued(_ message: QueuedMessage) async {
        await changeQueue("Removed from the queue") { try await $0.deleteQueued(self.id, message: message.id) }
    }

    func moveQueued(_ message: QueuedMessage, to position: Int) async {
        await changeQueue("Moved to \(position)") { _ = try await $0.moveQueued(self.id, message: message.id, to: position) }
    }

    /// Whether the server took the edit; the editor stays open with the text when it did not.
    func editQueued(_ message: QueuedMessage, content: String) async -> Bool {
        await changeQueue("Queued message updated") { _ = try await $0.editQueued(self.id, message: message.id, content: content) }
    }

    /// Remove an "also senior" edge from the hierarchy, then show the hierarchy as it now is.
    func detachUncle(_ junior: Int, uncle: Int) async {
        do {
            try await api.detachUncle(junior, uncle: uncle)
            notice = "Removed #\(uncle) as a senior of #\(junior)"
            Haptics.success()
            await load()
        } catch {
            fail(error)
        }
    }

    /// One change, then the queue as the server now has it.
    @discardableResult
    private func changeQueue(_ done: String, _ change: (ZimmerAPI) async throws -> Void) async -> Bool {
        do {
            try await change(api)
            queue = try await api.queue(id)
            notice = done
            error = nil
            Haptics.success()
            return true
        } catch {
            fail(error)
            if let fresh = try? await api.queue(id) { queue = fresh }
            return false
        }
    }
}
