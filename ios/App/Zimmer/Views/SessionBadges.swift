import SwiftUI
import ZimmerKit

/// The status pill, in the web UI's colours (`SessionsHelper#status_badge_classes`): needs
/// input blue, running green, waiting purple, failed orange, trashed gray. A tint on a light
/// wash of the same colour, as the web's `bg-*-100 text-*-800`, which also reads in dark mode.
struct StatusBadge: View {
    let status: SessionStatus
    var compact = false

    var body: some View {
        Text(Self.label(for: status))
            .font((compact ? Font.caption2 : .caption).weight(.semibold))
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 3)
            .foregroundStyle(StatusDot.color(for: status))
            .background(StatusDot.color(for: status).opacity(0.15), in: Capsule())
            .accessibilityLabel(Self.label(for: status))
    }

    /// The badge's words. The web UI's badge says "Trashed" for an archived session; its
    /// filter still says "Archived", and so do the chips here.
    static func label(for status: SessionStatus) -> String {
        status == .archived ? "Trashed" : status.label
    }
}

struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        Circle().fill(Self.color(for: status)).frame(width: 10, height: 10)
    }

    /// The one status → colour map in the app, matching the web UI's.
    static func color(for status: SessionStatus) -> Color {
        switch status {
        case .needsInput: return .blue
        case .running: return .green
        case .waiting: return .purple
        case .failed: return .orange
        case .archived, .unknown: return .gray
        }
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
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 0.5))
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
        switch state {
        case "merged": return .purple
        case "open": return .green
        case "closed": return .red
        default: return .gray
        }
    }

    /// `SessionsHelper#ci_status_bg_class`'s map, over `Github::PrStatusEvaluator`'s words.
    static func ciColor(_ ci: String) -> Color {
        switch ci {
        case "pass": return .green
        case "fail": return .red
        case "pending": return .yellow
        default: return .gray
        }
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
