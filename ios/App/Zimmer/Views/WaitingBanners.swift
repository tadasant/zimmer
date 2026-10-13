import SwiftUI
import ZimmerKit

/// The web UI's session-header banners: why the session is waiting — a spot hold, a quota
/// pause, a turn queued for a worker, an account pool out of quota — and the recovery ones,
/// a renewed MCP grant or an approval request that never came back. Each carries at most one
/// control: make it priority, force a worker thread, send the reconnect message, or finish
/// an authorization in the browser.
///
/// The words are the server's (`waiting` on `GET /api/v1/sessions/:id`), so the phone says
/// what the web page says, and the banners change as the page reads again.
struct WaitingBanners: View {
    let banners: [WaitingBanner]
    let perform: (WaitingBanner.Action) -> Void

    var body: some View {
        ForEach(banners) { banner in
            WaitingBannerCard(banner: banner) { perform($0) }
        }
    }
}

/// One banner: the headline in the tone's colour, the first paragraph, and the rest behind
/// *More* — the server's explanation runs to five paragraphs, and on a phone the first one
/// and the button are what a person acts on.
private struct WaitingBannerCard: View {
    let banner: WaitingBanner
    let perform: (WaitingBanner.Action) -> Void
    @State private var expanded = false

    var body: some View {
        let colors = Theme.banner(banner.tone)
        let shown = expanded ? banner.body : Array(banner.body.prefix(1))
        VStack(alignment: .leading, spacing: 6) {
            Text(banner.headline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.text)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.footnote)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if banner.action != nil || banner.body.count > 1 {
                HStack(spacing: 14) {
                    if let action = banner.action {
                        Button { perform(action) } label: {
                            Text(action.label)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Theme.accentFill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("waiting.action.\(banner.key)")
                    }
                    if banner.body.count > 1 {
                        Button(expanded ? "Less" : "More") {
                            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("waiting.more.\(banner.key)")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .themeCard(radius: Theme.smallRadius, fill: colors.fill)
        .overlay(alignment: .leading) {
            colors.dot.frame(width: 3).padding(.vertical, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("waiting.banner.\(banner.key)")
    }
}

/// The web UI's "N messages were never delivered" block: messages Zimmer accepted and will
/// not send, because the session was archived first or the news in them had gone stale.
/// Read-only — there is nothing left to send, reorder or edit — and shown rather than
/// hidden, since hiding them would be the silence the status exists to end.
struct UndeliveredCard: View {
    let messages: [QueuedMessage]

    var body: some View {
        let colors = Theme.banner(.warning)
        let them = messages.count == 1 ? "it" : "them"
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: messages.count == 1 ? "1 message was never delivered." : "\(messages.count) messages were never delivered.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(colors.text)
            Text(verbatim: "Either the session was archived before \(them) could be sent, or Zimmer retired \(them) because the state reported had already changed. The session log records which.")
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(messages) { message in
                Text(message.content)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("undelivered.message.\(message.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .themeCard(radius: Theme.smallRadius, fill: colors.fill)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("undelivered.list")
    }
}
