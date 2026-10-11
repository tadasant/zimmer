import SwiftUI
import ZimmerKit

/// The status pill, in the web UI's colours (`SessionsHelper#status_badge_classes`): needs
/// input blue, running green, waiting purple, failed orange, trashed gray — the web's
/// `bg-*-100 text-*-800` pastel in light, the same hue on a deep wash in dark (`Theme.status`).
/// A dot leads the word; a running session's dot wears a halo, where the web badge spins.
struct StatusBadge: View {
    let status: SessionStatus
    var compact = false

    var body: some View {
        let colors = Theme.status(status)
        let dot: CGFloat = compact ? 5 : 6
        // The Text stays the root, so UI tests and VoiceOver still read it as text; the dot
        // sits in the padding beside it.
        Text(Self.label(for: status))
            .font(.system(compact ? .caption2 : .caption, weight: .semibold))
            .padding(.leading, dot + (compact ? 4 : 5))
            .overlay(alignment: .leading) { StatusDot(status: status, size: dot) }
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 2.5 : 4)
            .foregroundStyle(colors.text)
            .background(colors.fill, in: Capsule())
            .accessibilityLabel(Self.label(for: status))
    }

    /// The badge's words. The web UI's badge says "Trashed" for an archived session; its
    /// filter still says "Archived", and so do the chips here.
    static func label(for status: SessionStatus) -> String {
        status == .archived ? "Trashed" : status.label
    }
}

/// Still, not pulsing: a repeating animation keeps the app from ever going idle, which is
/// what XCUITest waits for between steps.
struct StatusDot: View {
    let status: SessionStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Self.color(for: status))
            .frame(width: size, height: size)
            .background {
                if status == .running {
                    Circle().fill(Self.color(for: status).opacity(0.3)).frame(width: size * 2, height: size * 2)
                }
            }
    }

    /// The one status → colour map in the app, matching the web UI's.
    static func color(for status: SessionStatus) -> Color {
        Theme.status(status).dot
    }
}

/// A pull request button, coloured and shaped by its state as the web UI's is: open green,
/// merged purple, closed red, unknown gray.
struct PullRequestChip: View {
    let pullRequest: PullRequestLink

    var body: some View {
        Link(destination: pullRequest.url) {
            HStack(spacing: 4) {
                Image(systemName: Self.symbol(for: pullRequest.state))
                    .foregroundStyle(Self.color(for: pullRequest.state))
                Text(pullRequest.label)
                if pullRequest.state == "open", let ci = pullRequest.ci {
                    Circle().fill(Self.ciColor(ci)).frame(width: 7, height: 7)
                        .accessibilityLabel("CI \(ci)")
                }
            }
            .font(.footnote.weight(.semibold).monospacedDigit())
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.rule, lineWidth: 1))
        }
        .accessibilityLabel("PR \(pullRequest.label), \(pullRequest.state ?? "unknown")")
        .accessibilityIdentifier("detail.pr.\(pullRequest.label)")
    }

    static func symbol(for state: String?) -> String {
        switch state {
        case "merged": return "arrow.triangle.merge"
        case "closed": return "xmark.circle"
        default: return "arrow.triangle.pull"
        }
    }

    static func color(for state: String?) -> Color {
        Theme.pullRequest(state)
    }

    /// `SessionsHelper#ci_status_bg_class`'s map, over `Github::PrStatusEvaluator`'s words.
    static func ciColor(_ ci: String) -> Color {
        Theme.ci(ci)
    }
}

/// "Snoozed until …" or "Hidden": shown wherever a tucked-away session is drawn.
struct VisibilityLabel: View {
    let session: SessionSummary

    var body: some View {
        switch session.boardVisibility {
        case .visible:
            EmptyView()
        case .hidden:
            Label("Hidden", systemImage: "eye.slash")
        case .snoozed:
            if let until = session.snoozedUntil {
                Label {
                    Text("Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))")
                } icon: {
                    Image(systemName: "moon.zzz")
                }
            } else {
                Label("Snoozed", systemImage: "moon.zzz")
            }
        }
    }
}
