import SwiftUI
import ZimmerKit

/// One session's state, for the detail screen. Holds no rules of its own: what can be
/// followed up or archived is `SessionDetail`'s, what happens is the server's.
@MainActor
final class SessionDetailModel: ObservableObject {
    let id: Int
    private let api: ZimmerAPI

    @Published private(set) var detail: SessionDetail?
    @Published private(set) var conversation: Conversation?
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published var error: ZimmerError?
    @Published var notice: String?
    @Published var draft = ""

    init(id: Int, api: ZimmerAPI) {
        self.id = id
        self.api = api
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await api.session(id)
            error = nil
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
            return
        }
        // A session with no transcript yet answers 404 here; that is an empty
        // conversation, not a broken screen.
        conversation = (try? await api.conversation(id)) ?? Conversation(messages: [])
    }

    func send() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            let result = try await api.followUp(id, prompt: prompt)
            draft = ""
            notice = result.queued ? "Queued — it goes in when the current turn ends." : "Sent."
            error = nil
            await load()
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
        }
    }

    func archive() async -> Bool {
        do {
            _ = try await api.archive(id)
            return true
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
            return false
        }
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SessionDetailModel
    @State private var confirmingArchive = false
    @State private var showingToolTraffic = false

    /// Short answers a person gives most often — on a phone, typing is the expensive part.
    static let quickReplies = ["Yes, go ahead.", "Merge it.", "Not yet — hold off."]

    init(id: Int, api: ZimmerAPI) {
        _model = StateObject(wrappedValue: SessionDetailModel(id: id, api: api))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let detail = model.detail {
                    header(detail)
                    if let summary = detail.statusSummary?.summary {
                        SummaryCard(text: summary)
                    }
                } else if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
                if let error = model.error { ErrorBanner(error: error) }
                if let conversation = model.conversation {
                    conversationSection(conversation)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("#\(model.id)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmingArchive = true } label: {
                    Image(systemName: "archivebox")
                }
                .disabled(!(model.detail?.canArchive ?? false))
                .accessibilityLabel("Archive session")
                .accessibilityIdentifier("detail.archive")
            }
        }
        .confirmationDialog("Archive this session?", isPresented: $confirmingArchive, titleVisibility: .visible) {
            Button("Archive", role: .destructive) {
                Task {
                    if await model.archive() {
                        await app.sessionChanged()
                        dismiss()
                    }
                }
            }
            .accessibilityIdentifier("archive.confirm")
        } message: {
            Text("It moves to the trash and can be restored from Zimmer's web UI.")
        }
        .safeAreaInset(edge: .bottom) {
            if model.detail?.acceptsFollowUp ?? false { composer }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    private func header(_ detail: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusDot(status: detail.session.status)
                Text(detail.session.status.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StatusDot.color(for: detail.session.status))
                    .accessibilityIdentifier("detail.status")
            }
            Text(detail.session.displayTitle)
                .font(.title2.weight(.bold))
                .accessibilityIdentifier("detail.title")
            HStack(spacing: 6) {
                if let runtime = detail.session.agentRuntime { Text(runtime) }
                if let date = detail.session.updatedAt ?? detail.session.createdAt {
                    Text("·")
                    Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func conversationSection(_ conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Conversation").font(.headline)
                Spacer()
                if conversation.messages.contains(where: \.isToolTraffic) {
                    Toggle("Tool calls", isOn: $showingToolTraffic)
                        .toggleStyle(.button)
                        .font(.caption)
                }
            }
            if conversation.truncated {
                Text("Showing the last \(conversation.messages.count) of \(conversation.total) messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if conversation.messages.isEmpty {
                Text("No transcript yet.").foregroundStyle(.secondary)
            }
            ForEach(conversation.messages.filter { showingToolTraffic || !$0.isToolTraffic }) { message in
                MessageBubble(message: message)
            }
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("followup.notice")
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.quickReplies, id: \.self) { reply in
                        Button(reply) { model.draft = reply }
                            .buttonStyle(.bordered)
                            .font(.footnote)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply to the agent", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("followup.field")
                Button {
                    Task { await model.send() }
                } label: {
                    Image(systemName: model.isSending ? "hourglass" : "arrow.up.circle.fill")
                        .font(.system(size: 32))
                }
                .disabled(model.isSending || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("followup.send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct SummaryCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where things stand").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.summary")
    }
}

private struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        let fromAgent = message.role == .assistant
        VStack(alignment: fromAgent ? .leading : .trailing, spacing: 4) {
            Text(message.isToolTraffic ? "Tool" : (fromAgent ? "Agent" : "You"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message.content)
                .font(message.isToolTraffic ? .caption.monospaced() : .body)
                .padding(10)
                .background(
                    fromAgent ? Color(.secondarySystemGroupedBackground) : Color.accentColor.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: fromAgent ? .leading : .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.message.\(message.id)")
    }
}
