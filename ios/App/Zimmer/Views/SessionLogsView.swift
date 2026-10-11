import SwiftUI
import ZimmerKit

/// The web UI's "Show Logs": what Zimmer did around the agent — clones, starts, retries,
/// warnings — newest first, fifty at a time.
struct SessionLogsView: View {
    let id: Int
    let api: ZimmerAPI
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [LogEntry] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: ZimmerError?

    var body: some View {
        NavigationStack {
            List {
                if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text((entry.level ?? "info").uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Self.color(for: entry.level))
                            if let date = entry.createdAt {
                                Text(date, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Theme.inkMute)
                            }
                        }
                        Text(entry.content)
                            .font(.footnote.monospaced())
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(Theme.ground)
                    .listRowSeparatorTint(Theme.rule)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("log.\(entry.id)")
                }
                if hasMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Theme.ground)
                        .listRowSeparator(.hidden)
                        .task { await loadMore() }
                }
            }
            .listStyle(.plain)
            .themeGround()
            .overlay {
                if entries.isEmpty && !hasMore && error == nil {
                    EmptyState(title: "No logs", symbol: "doc.plaintext")
                }
            }
            .refreshable { await reload() }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func reload() async {
        entries = []
        page = 0
        hasMore = true
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await api.logs(id, page: page + 1)
            // A running session logs while you scroll, which shifts the pages: a row seen on
            // the last page can come round again on this one.
            let seen = Set(entries.map(\.id))
            entries += next.entries.filter { !seen.contains($0.id) }
            page += 1
            hasMore = next.hasMore
            error = nil
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
            hasMore = false
        }
    }

    /// The web UI's log-level colours.
    static func color(for level: String?) -> Color {
        switch level {
        case "error": return Theme.danger
        case "warning": return Theme.warning
        case "debug", "verbose": return Theme.inkMute
        default: return Theme.accent
        }
    }
}

/// The subagents a session ran, each opening its own transcript — the web UI's subagent
/// accordions, as a list.
struct SubagentsView: View {
    let id: Int
    let api: ZimmerAPI
    @Environment(\.dismiss) private var dismiss
    @State private var transcripts: [SubagentTranscriptSummary]?
    @State private var error: ZimmerError?

    var body: some View {
        NavigationStack {
            List {
                if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                ForEach(transcripts ?? []) { transcript in
                    NavigationLink {
                        SubagentTranscriptView(id: id, transcript: transcript, api: api)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(transcript.title).lineLimit(2).foregroundStyle(Theme.ink)
                            HStack(spacing: 6) {
                                if let status = transcript.status { Text(status.capitalized) }
                                if let duration = transcript.duration { Text("·"); Text(duration) }
                                if let tokens = transcript.tokens { Text("·"); Text("\(tokens) tokens") }
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.inkSoft)
                        }
                    }
                    .accessibilityIdentifier("subagent.\(transcript.id)")
                    .themeRows()
                }
            }
            .themeGround()
            .overlay {
                if transcripts == nil && error == nil { LoadingState() }
                if transcripts?.isEmpty == true { EmptyState(title: "No subagents", symbol: "person.2") }
            }
            .task {
                do {
                    transcripts = try await api.subagentTranscripts(id)
                } catch {
                    self.error = error as? ZimmerError ?? .transport(error)
                    transcripts = []
                }
            }
            .navigationTitle("Subagents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct SubagentTranscriptView: View {
    let id: Int
    let transcript: SubagentTranscriptSummary
    let api: ZimmerAPI
    @State private var messages: [ConversationMessage]?
    @State private var error: ZimmerError?
    @State private var showingToolTraffic = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let error { ErrorBanner(error: error) }
                if messages?.contains(where: \.isToolTraffic) == true {
                    // Folded, as the session's own conversation is.
                    Toggle("Tool calls", isOn: $showingToolTraffic)
                        .toggleStyle(.button)
                        .font(.caption)
                }
                ForEach((messages ?? []).filter { showingToolTraffic || !$0.isToolTraffic }) { MessageBubble(message: $0) }
                if messages?.isEmpty == true {
                    Text("No transcript recorded.").font(.subheadline).foregroundStyle(Theme.inkMute)
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.vertical, 12)
        }
        .background(Theme.ground)
        .overlay { if messages == nil && error == nil { LoadingState() } }
        .navigationTitle(transcript.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                messages = try await api.subagentTranscript(id, transcript: transcript.id)
            } catch {
                self.error = error as? ZimmerError ?? .transport(error)
            }
        }
    }
}
