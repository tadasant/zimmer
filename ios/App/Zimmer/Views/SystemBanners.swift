import SwiftUI
import ZimmerKit

/// The web layout's two site-wide alerts (`_queue_recovery_mode_banner`,
/// `_network_health_banner`), one line each, in the colours the web uses: amber for a
/// deliberate halt, red for an outage. Drawn on the board and at the head of Health.
struct SystemBannerRows: View {
    let banners: SystemBanners
    /// Where the web banner's *Manage* link goes: Health.
    var open: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            if let recovery = banners.queueRecovery {
                banner(tone: Theme.warning, symbol: "pause.circle.fill", identifier: "banner.queueRecovery") {
                    Text("Queue recovery mode.").bold()
                    + Text(" Background jobs are halted on \(recovery.haltedQueues.joined(separator: ", ")); agent sessions still run.")
                    + reason(recovery)
                    + resumes(recovery)
                }
            }
            if let egress = banners.egressDegraded {
                banner(tone: Theme.danger, symbol: "network.slash", identifier: "banner.egress") {
                    Text("Network egress degraded.").bold()
                    + Text(" The worker's primary DNS resolver can't reach the internet — new agent logins and sessions may fail.")
                    + (egress.degradedSince.map { Text(" Since \($0.formatted(date: .abbreviated, time: .shortened)).") } ?? Text(""))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func reason(_ recovery: HealthReport.QueueRecovery) -> Text {
        guard let reason = recovery.reason, !reason.isEmpty else { return Text("") }
        return Text(" Reason: \(reason.count > 120 ? String(reason.prefix(119)) + "…" : reason).")
    }

    private func resumes(_ recovery: HealthReport.QueueRecovery) -> Text {
        guard let seconds = recovery.expiresInSeconds ?? recovery.expiresAt.map({ $0.timeIntervalSinceNow }) else { return Text("") }
        return Text(" Auto-resumes in \(Format.duration(seconds)).")
    }

    private func banner(tone: Color, symbol: String, identifier: String, @ViewBuilder text: () -> Text) -> some View {
        Button {
            open?()
        } label: {
            Label {
                text().font(.footnote).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tone)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .themeCard(radius: Theme.smallRadius, fill: tone.opacity(0.1))
            .overlay(alignment: .leading) { tone.frame(width: 3).padding(.vertical, 10) }
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
        .accessibilityIdentifier(identifier)
    }
}
