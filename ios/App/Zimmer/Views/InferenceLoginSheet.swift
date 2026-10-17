import SwiftUI
import ZimmerKit

/// The web card's login panel as a sheet: it polls the attempt every two seconds, as the
/// page's `inference-login-poller` does, and draws each state — waiting for the link, the
/// link to open, the one-time code to enter (Codex), the code to paste back (Claude),
/// finishing, done, failed — with Cancel the whole way.
struct InferenceLoginSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let account: InferenceAccount
    @State private var attempt: LoginAttempt
    @State private var code = ""
    @State private var error: String?
    /// The poller gave up: the server lost the attempt, or it ran out of time.
    @State private var abandoned: String?
    @State private var copied = false
    @State private var submitting = false

    /// The page's cadence, and its budget for a server that stops answering.
    private static let interval: Duration = .seconds(2)
    private static let maxBackoff: Duration = .seconds(30)
    private static let maxConsecutiveErrors = 10

    init(account: InferenceAccount, attempt: LoginAttempt) {
        self.account = account
        _attempt = State(initialValue: attempt)
    }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if abandoned == nil {
                    if attempt.showsLink { linkSection }
                    if attempt.showsLink, let code = attempt.verificationCode { codeSection(code) }
                    if attempt.awaitingCode && !attempt.codeReceived { pasteSection }
                }
                if let error {
                    Section { Text(error).font(.caption).foregroundStyle(Theme.danger).accessibilityIdentifier("inference.login.error") }
                }
            }
            .navigationTitle("Authenticate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task { await poll() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if attempt.terminal || abandoned != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.accessibilityIdentifier("inference.login.done")
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { Task { await cancel() } }.accessibilityIdentifier("inference.login.cancel")
            }
        }
    }

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Authenticating \(account.email)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                HStack(spacing: 8) {
                    if !attempt.terminal && abandoned == nil { ProgressView().controlSize(.small) }
                    Text(abandoned ?? attempt.headline)
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                        .accessibilityIdentifier("inference.login.status")
                }
                if attempt.succeeded {
                    Text("The account can serve sessions. It authenticated as the email it was added under.")
                        .font(.caption).foregroundStyle(Theme.inkSoft)
                }
            }
            .padding(.vertical, 2)
        } footer: {
            if let expires = attempt.expiresAt, !attempt.terminal, abandoned == nil {
                Text("This login expires \(expires.formatted(.relative(presentation: .named))).").font(.caption).foregroundStyle(Theme.inkMute)
            }
        }
    }

    private var statusColor: Color {
        if abandoned != nil { return Theme.warning }
        switch attempt.status {
        case "succeeded": return Theme.success
        case "failed", "expired": return Theme.danger
        default: return Theme.inkSoft
        }
    }

    private var linkSection: some View {
        Section {
            if let raw = attempt.verificationURL, let url = URL(string: raw) {
                Button {
                    openURL(url)
                } label: {
                    Label("Open the link and authorize", systemImage: "safari")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .accessibilityIdentifier("inference.login.url")
                Text(raw).font(Theme.mono).foregroundStyle(Theme.inkSoft).textSelection(.enabled)
            } else {
                Text("(waiting for link…)").font(.subheadline).foregroundStyle(Theme.inkMute)
                    .accessibilityIdentifier("inference.login.url")
            }
        } header: {
            Text("1. Authorize")
        }
    }

    private func codeSection(_ code: String) -> some View {
        Section {
            HStack {
                Text(code)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("inference.login.code")
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = code
                    copied = true
                    Haptics.selection()
                }
                .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                .accessibilityIdentifier("inference.login.copy")
            }
        } header: {
            Text("2. Enter this one-time code")
        } footer: {
            Text("Tokens are captured automatically once you approve — nothing to paste back.")
        }
    }

    private var pasteSection: some View {
        Section {
            TextField("Paste code here", text: $code)
                .font(Theme.mono)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("inference.login.codeField")
            Button("Submit") { Task { await submit() } }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                .disabled(submitting || code.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("inference.login.submit")
        } header: {
            Text("2. Paste the authorization code the page shows")
        }
    }

    // MARK: - The poll

    /// The page's poller: every two seconds while the attempt is live, backing off on a
    /// server that stops answering and giving up after ten misses, or at the deadline. A
    /// refusal is final at once.
    private func poll() async {
        let deadline = attempt.expiresAt.map { $0.addingTimeInterval(60) }
        var errors = 0
        while !Task.isCancelled, !attempt.terminal, abandoned == nil {
            let delay = errors == 0 ? Self.interval : min(Self.interval * (1 << (errors - 1)), Self.maxBackoff)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            if let deadline, Date() > deadline {
                abandoned = "This login didn't finish in time and has been abandoned. Authenticate again."
                return
            }
            do {
                let polled = try await app.api.inferenceLogin(attempt.id)
                attempt = polled.login
                errors = 0
                if attempt.succeeded { Haptics.success() }
            } catch let ZimmerError.http(status, _) where status == 404 {
                abandoned = "This login is no longer being tracked — its record was removed while it was in flight, or the account it was for was deleted. Authenticate again if an account still needs credentials."
                return
            } catch let ZimmerError.http(status, message) where (400..<500).contains(status) {
                // The poll is person-only: a relay grant's 403 is an answer, not an outage.
                abandoned = message ?? ZimmerError.http(status: status, message: nil).userMessage
                return
            } catch {
                errors += 1
                if errors >= Self.maxConsecutiveErrors {
                    abandoned = "Lost contact with the server while finishing sign-in, so this login's outcome is unknown. Reopen the page to see the account's current state."
                    return
                }
            }
        }
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        do {
            attempt = try await app.api.submitInferenceLoginCode(attempt.id, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            error = nil
            Haptics.success()
        } catch {
            self.error = (error as? ZimmerError ?? .transport(error)).userMessage
            Haptics.failure()
        }
    }

    private func cancel() async {
        if let canceled = try? await app.api.cancelInferenceLogin(attempt.id) { attempt = canceled }
        dismiss()
    }
}
