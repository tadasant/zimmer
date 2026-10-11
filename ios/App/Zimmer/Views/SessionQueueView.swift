import SwiftUI
import ZimmerKit

/// The web UI's queued-messages panel: what is waiting for the turn in flight to end, in
/// delivery order. Each message can be sent now (ending the turn), edited or deleted;
/// *Manage* opens the whole queue to drag into a new order.
struct QueueCard: View {
    @ObservedObject var model: SessionDetailModel
    @State private var editing: QueuedMessage?
    @State private var managing = false
    @State private var deleting: QueuedMessage?

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
                        // Only where the server can deliver it: a paused or failed session refuses.
                        if model.detail?.acceptsFollowUp ?? false {
                            Button {
                                Task { await model.sendQueuedNow(message) }
                            } label: {
                                Label("Send Now", systemImage: "bolt.fill")
                            }
                        }
                        Button { editing = message } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { deleting = message } label: {
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
        .confirmationDialog(
            "Delete this queued message?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let message = deleting { Task { await model.deleteQueued(message) } }
            }
        }
        .sheet(item: $editing) { message in
            QueuedMessageEditor(message: message) { text in
                await model.editQueued(message, content: text) ? nil : model.error
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
                // Here, not on the page behind the sheet.
                if let error = model.error { ErrorBanner(error: error).listRowInsets(EdgeInsets()) }
                ForEach(model.queue) { message in
                    Text(message.content).lineLimit(3)
                }
                .onMove { source, destination in
                    guard let from = source.first, destination != from, destination != from + 1 else { return }
                    let message = model.queue[from]
                    // The position of the row it lands beside, as the server numbers it — not
                    // the list index, since an undelivered message can hold a lower position
                    // than any of these.
                    let position = destination > from ? model.queue[destination - 1].position : model.queue[destination].position
                    model.queue.move(fromOffsets: source, toOffset: destination)
                    Task { await model.moveQueued(message, to: position) }
                }
                .onDelete { offsets in
                    let doomed = offsets.map { model.queue[$0] }
                    model.queue.remove(atOffsets: offsets)
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

/// Rewrite one queued message before it is delivered. `save` answers the server's refusal,
/// or nil when it took the edit.
private struct QueuedMessageEditor: View {
    let message: QueuedMessage
    let save: (String) async -> ZimmerError?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @State private var error: ZimmerError?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error { ErrorBanner(error: error).padding([.horizontal, .top]) }
                TextEditor(text: $text)
                    .padding()
                    .accessibilityIdentifier("queue.edit.text")
            }
                .navigationTitle("Edit queued message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Saving…" : "Save") {
                            Task {
                                saving = true
                                error = await save(text.trimmingCharacters(in: .whitespacesAndNewlines))
                                saving = false
                                if error == nil { dismiss() }
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
        // The page reloads only on success: a reload would clear the refusal from view.
        if await changeQueue("Sent now — the current turn ends.", { try await $0.sendQueuedNow(self.id, message: message.id) }) {
            await load()
        }
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
