import SwiftUI
import ZimmerKit

/// One account as the web page's card draws it: the email with the Current marker and the
/// status badge, the header's tags (a failed probe, quota hits, the reading's age, the
/// credential tag), the two quota bars with their reset lines, the credential verdict and
/// the login panel, then the verbs: Refresh, Switch, Delete, Authenticate.
struct InferenceAccountCard: View {
    let account: InferenceAccount
    let busy: Bool
    /// A verb's refusal, kept under the card until the next verb on it.
    let error: String?
    let refresh: () -> Void
    let activate: () -> Void
    let delete: () -> Void
    let authenticate: () -> Void
    /// Open the login sheet on the attempt already in flight.
    let resume: (LoginAttempt) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            tags
            quota
            loginPanel
            actions
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("inference.error")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inference.account.\(account.id)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(account.email)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if account.isCurrent {
                pill("Current", Theme.accent).accessibilityIdentifier("inference.account.\(account.id).current")
            }
            pill(account.statusLabel, statusColor).accessibilityIdentifier("inference.account.\(account.id).status")
        }
    }

    private var statusColor: Color {
        switch account.effectiveStatus {
        case "active": return Theme.success
        case "quota_exceeded": return Theme.danger
        case "needs_reauth": return Theme.warning
        default: return Theme.inkMute
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }

    @ViewBuilder
    private var tags: some View {
        HStack(spacing: 8) {
            if account.probeError != nil { Text("Probe failed").foregroundStyle(Theme.danger) }
            if account.quotaHitCount > 0 { Text(verbatim: "\(account.quotaHitCount) hits") }
            if let taken = account.quota?.takenAt {
                Text(verbatim: InferenceFormat.ageLine(taken)).accessibilityLabel("read \(taken.formatted(.relative(presentation: .named)))")
            }
            if let tag = account.credentialTag {
                Text(tag).foregroundStyle(tag == "Token refused" ? Theme.danger : Theme.inkSoft)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(Theme.inkMute)
        if let probeError = account.probeError {
            Text(probeError).font(.caption).foregroundStyle(Theme.danger)
                .accessibilityIdentifier("inference.account.\(account.id).probeError")
        }
    }

    @ViewBuilder
    private var quota: some View {
        if let note = account.codexNote {
            Text(note).font(.caption).foregroundStyle(Theme.inkSoft)
        } else if let quota = account.quota {
            window("5h", quota.fiveHour, identifier: "window5h")
            if quota.fiveHourHeadroomUnusable {
                Text("Left out of the pool's 5-hour figure — the 7-day window is spent, and it reads 100% on the 7-day figure instead")
                    .font(.caption2).foregroundStyle(Theme.warning)
            }
            window("7d", quota.sevenDay, identifier: "window7d")
            HStack(spacing: 10) {
                if let plan = quota.subscriptionType { Text("Plan: \(plan)") }
                if let tier = quota.rateLimitTier { Text("Tier: \(tier)") }
            }
            .font(.caption2).foregroundStyle(Theme.inkMute)
        } else {
            Text("No quota data available. Tap Refresh to fetch live data.").font(.caption).foregroundStyle(Theme.inkSoft)
        }
    }

    /// One window: the label and badge, the percentage, the bar, and where the window stands.
    private func window(_ label: String, _ window: InferenceAccount.Window, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
                if let badge = window.badge {
                    pill(badge, badge == "Allowed" ? Theme.success : Theme.danger)
                }
                Spacer()
                Text(window.percentText).font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(Theme.ink)
            }
            ProgressView(value: window.fraction)
                .tint(barColor(window.fraction))
            if let line = window.resetLine() {
                Text(line).font(.caption2).foregroundStyle(line == "Window reset" ? Theme.success : Theme.inkMute)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inference.account.\(account.id).\(identifier)")
    }

    /// The web bar's colours: green with room, amber past 60%, red past 85%.
    private func barColor(_ fraction: Double) -> Color {
        if fraction >= 0.85 { return Theme.danger }
        if fraction >= 0.6 { return Theme.warning }
        return Theme.success
    }

    @ViewBuilder
    private var loginPanel: some View {
        if let attempt = account.login.activeAttempt {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Authenticating \(account.email)").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    Text(attempt.headline).font(.caption).foregroundStyle(Theme.inkSoft).lineLimit(2)
                }
                Spacer()
                Button("Open") { resume(attempt) }
                    .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                    .accessibilityIdentifier("inference.account.\(account.id).resumeLogin")
            }
        } else if account.login.available {
            let line = account.credentialLine()
            Text(line.text).font(.caption).foregroundStyle(credentialColor(line.tone))
                .accessibilityIdentifier("inference.account.\(account.id).credentials")
            if let failure = account.login.lastFailureLine {
                Text(failure).font(.caption).foregroundStyle(Theme.danger)
            }
        }
    }

    private func credentialColor(_ tone: InferenceAccount.CredentialTone) -> Color {
        switch tone {
        case .plain: return Theme.inkSoft
        case .warning: return Theme.warning
        case .danger: return Theme.danger
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if !account.isCodex {
                Button("Refresh", action: refresh)
                    .accessibilityIdentifier("inference.account.\(account.id).refresh")
            }
            if let label = account.activateLabel {
                Button(label, action: activate)
                    .tint(Theme.accent)
                    .disabled(!account.credentials.stored)
                    .accessibilityIdentifier("inference.account.\(account.id).activate")
                    .accessibilityHint(account.credentials.stored ? "" : "No tokens — authenticate the account first")
            }
            Button("Delete", role: .destructive, action: delete)
                .tint(Theme.danger)
                .accessibilityIdentifier("inference.account.\(account.id).delete")
            if account.login.available, account.login.activeAttempt == nil {
                Button(account.authenticateLabel, action: authenticate)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("inference.account.\(account.id).authenticate")
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(busy)
    }
}
