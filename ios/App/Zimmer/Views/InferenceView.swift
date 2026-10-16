import SwiftUI
import ZimmerKit

/// The web UI's Inference page: the runtime tabs, each account's card with its quota
/// windows and the verbs the page offers, Add account and the login flow, the rotation
/// log, the dry-pool banner, the Pi tab's OpenRouter key (state only), and the three policy
/// forms. Every write takes the app's sign-in acting as you; a relay-only grant sees the
/// server's 403 in place.
struct InferenceView: View {
    @EnvironmentObject private var app: AppModel
    @State private var runtime: String
    @State private var report: InferenceReport?
    @State private var error: ZimmerError?
    /// An account verb's refusal, under the card it was for.
    @State private var accountError: (id: Int, message: String)?
    @State private var adding = false
    @State private var login: LoginTarget?
    @State private var confirming: AccountConfirmation?
    /// Accounts with a verb in flight: a second tap waits for the first.
    @State private var busy: Set<Int> = []
    @State private var expandedLog = false
    /// `-ZimmerFixtureInferenceLogin`: the first account that can log in starts one on load.
    private let opensLogin: Bool

    init(runtime: String = InferenceReport.claudeCode, opensLogin: Bool = false) {
        _runtime = State(initialValue: runtime)
        self.opensLogin = opensLogin
    }

    /// Which account the login sheet is for, and the attempt it drives.
    struct LoginTarget: Identifiable {
        let account: InferenceAccount
        let attempt: LoginAttempt
        var id: Int { attempt.id }
    }

    enum AccountConfirmation: Identifiable {
        case activate(InferenceAccount)
        case delete(InferenceAccount)

        var id: String {
            switch self {
            case let .activate(account): return "activate.\(account.id)"
            case let .delete(account): return "delete.\(account.id)"
            }
        }

        var account: InferenceAccount {
            switch self {
            case let .activate(account), let .delete(account): return account
            }
        }

        var question: String {
            switch self {
            case let .activate(account): return account.activateConfirmation
            case let .delete(account): return account.deleteConfirmation
            }
        }
    }

    var body: some View {
        sheets(list)
            .navigationTitle("Inference")
            .navigationBarTitleDisplayMode(.inline)
    }

    private var list: some View {
        List {
            tabs
            if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            if let report {
                if report.isPi {
                    OpenRouterKeyCard(key: report.openrouterKey)
                } else {
                    roster(report)
                }
                if report.showsPolicy { policy(report) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.immediately)
        .themeGround()
        .overlay { if report == nil && error == nil { LoadingState() } }
        .task(id: runtime) { await load() }
        .refreshable { await load() }
    }

    private func sheets(_ content: some View) -> some View {
        content
            .sheet(isPresented: $adding) {
                AddAccountSheet(runtime: runtime, label: report?.runtimeLabel ?? runtime) { account in
                    await added(account)
                }
            }
            .sheet(item: $login, onDismiss: { Task { await load() } }) { target in
                InferenceLoginSheet(account: target.account, attempt: target.attempt)
            }
            .confirmationDialog(
                confirming?.question ?? "",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible,
                presenting: confirming
            ) { confirmation in
                switch confirmation {
                case let .activate(account):
                    Button(account.activateLabel ?? "Make current") { Task { await activate(account) } }
                        .accessibilityIdentifier("inference.confirm.activate")
                case let .delete(account):
                    Button("Delete", role: .destructive) { Task { await delete(account) } }
                        .accessibilityIdentifier("inference.confirm.delete")
                }
            }
    }

    // MARK: - Tabs

    /// The page's runtime sub-tabs, as buttons so each carries its own identifier.
    private var tabs: some View {
        Section {
            HStack(spacing: 6) {
                ForEach(report?.runtimes ?? InferenceReport.defaultRuntimes) { option in
                    Button {
                        guard option.key != runtime else { return }
                        report = nil
                        runtime = option.key
                    } label: {
                        Text(option.label)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(option.key == runtime ? Theme.accent : Theme.inkSoft)
                    .background(option.key == runtime ? Theme.accent.opacity(0.12) : Color.clear, in: Capsule())
                    .accessibilityAddTraits(option.key == runtime ? .isSelected : [])
                    .accessibilityIdentifier("inference.tab.\(option.key)")
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
        } footer: {
            Text(subtitle).font(.caption).foregroundStyle(Theme.inkMute)
        }
    }

    private var subtitle: String {
        switch runtime {
        case InferenceReport.pi: return "Pi pools no accounts — it resolves a provider key per request. This tab manages that key."
        case InferenceReport.codex: return "The Codex accounts sessions run on, and which one is current."
        default: return "The Claude Code accounts sessions run on, their quota windows, and the policy that paces spot work into them."
        }
    }

    // MARK: - The roster

    @ViewBuilder
    private func roster(_ report: InferenceReport) -> some View {
        if let dry = report.pool?.dry, let accounts = report.accounts {
            DryPoolBanner(runtime: report.runtimeLabel, count: accounts.count, dry: dry)
        }
        if let pool = report.pool, runtime == InferenceReport.claudeCode, pool.total > 0 {
            PoolCard(pool: pool)
        }
        Section {
            if let accounts = report.accounts, !accounts.isEmpty {
                ForEach(accounts) { account in
                    InferenceAccountCard(
                        account: account, busy: busy.contains(account.id),
                        error: accountError?.id == account.id ? accountError?.message : nil,
                        refresh: { Task { await refresh(account) } },
                        activate: { confirming = .activate(account) },
                        delete: { confirming = .delete(account) },
                        authenticate: { Task { await startLogin(account) } },
                        resume: { attempt in login = LoginTarget(account: account, attempt: attempt) }
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No \(report.runtimeLabel) accounts configured.").font(.subheadline).foregroundStyle(Theme.ink)
                    Text("Use Add account to create one.").font(.caption).foregroundStyle(Theme.inkSoft)
                }
            }
            Button {
                adding = true
            } label: {
                Label("Add \(report.runtimeLabel) account", systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityIdentifier("inference.add")
        } header: {
            Text("Accounts").themeLabel()
        }
        .themeRows()
        if let log = report.rotationLog, !log.isEmpty {
            RotationLogSection(events: log, expanded: $expandedLog) { id in app.path = [id] }
        }
    }

    @ViewBuilder
    private func policy(_ report: InferenceReport) -> some View {
        SpotPolicyForm(policy: report.spotPolicy) { change in
            try await app.api.updateSpotPolicy(change)
        } saved: { policy in
            self.report?.spotPolicy = policy
        }
        FleetTopUpForm(policy: report.fleetTopUp) { change in
            try await app.api.updateFleetTopUp(change)
        } saved: { policy in
            self.report?.fleetTopUp = policy
        }
        GenesisClassesSection(classes: report.genesisClasses) { genesis, target in
            try await app.api.setGenesisClass(genesis, to: target)
        } reset: {
            try await app.api.resetGenesisClasses()
        } changed: { classes in
            self.report?.genesisClasses = classes
        }
    }

    // MARK: - Reads and writes

    private func load() async {
        do {
            let loaded = try await app.api.inference(runtime: runtime)
            guard !Task.isCancelled else { return }
            report = loaded
            error = nil
            if opensLogin, login == nil, let first = loaded.accounts?.first(where: { $0.login.available && !$0.credentials.stored }) {
                await startLogin(first)
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error as? ZimmerError ?? .transport(error)
            app.noteError(self.error!)
        }
    }

    /// One verb on one account: the refusal stays under the card until the next verb on it.
    private func act(_ account: InferenceAccount, _ action: () async throws -> Void) async {
        guard busy.insert(account.id).inserted else { return }
        defer { busy.remove(account.id) }
        accountError = nil
        do {
            try await action()
            Haptics.success()
        } catch {
            let failure = error as? ZimmerError ?? .transport(error)
            accountError = (account.id, failure.userMessage)
            Haptics.failure()
        }
    }

    private func refresh(_ account: InferenceAccount) async {
        await act(account) {
            let refreshed = try await app.api.refreshInferenceAccount(account.id)
            replace(refreshed.account)
            if let pool = refreshed.pool { report?.pool = pool }
        }
    }

    private func activate(_ account: InferenceAccount) async {
        await act(account) {
            _ = try await app.api.activateInferenceAccount(account.id)
            await load()
        }
    }

    private func delete(_ account: InferenceAccount) async {
        await act(account) {
            _ = try await app.api.deleteInferenceAccount(account.id)
            await load()
        }
    }

    private func startLogin(_ account: InferenceAccount) async {
        await act(account) {
            let attempt = try await app.api.startInferenceLogin(accountID: account.id)
            login = LoginTarget(account: account, attempt: attempt)
        }
    }

    /// An account just added: on the roster, and, for one that needs a login, straight into it.
    private func added(_ account: InferenceAccount) async {
        await load()
        if account.login.available, !account.credentials.stored { await startLogin(account) }
    }

    private func replace(_ account: InferenceAccount) {
        guard let index = report?.accounts?.firstIndex(where: { $0.id == account.id }) else { return }
        report?.accounts?[index] = account
    }
}

/// The web page's dry-pool banner: above everything else, because when it fires nothing in
/// the pool can serve a session.
private struct DryPoolBanner: View {
    let runtime: String
    let count: Int
    let dry: InferencePool.Dry

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("No \(runtime) account can serve a session").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.danger)
                Text("All \(count) account\(count == 1 ? "" : "s") in this pool are unusable: \(dry.breakdown).").font(.caption).foregroundStyle(Theme.ink)
                Text(dry.recovery).font(.caption).foregroundStyle(Theme.inkSoft)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("inference.pool.dry")
        }
        .themeRows()
    }
}

/// The Account Pool card's counts and averaged windows.
private struct PoolCard: View {
    let pool: InferencePool

    var body: some View {
        Section {
            HStack(spacing: 0) {
                figure("\(pool.total)", "Total")
                figure("\(pool.active)", "Active")
                figure("\(pool.quotaExceeded)", "Quota exceeded")
                figure("\(pool.needsReauth)", "Needs reauth")
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("inference.pool")
            LabeledContent("5-hour window, averaged", value: percent(pool.fiveHourUtilization))
            LabeledContent("7-day window, averaged", value: percent(pool.weeklyUtilization))
            if let reset = pool.nextWeeklyReset, pool.weeklySpentCount > 0 {
                LabeledContent("Next 7-day reset", value: "in \(InferenceFormat.duration(reset.timeIntervalSinceNow))")
            }
        } header: {
            Text("Account pool").themeLabel()
        } footer: {
            Text(pool.capacityNow ? "Work is not blocked." : "Every account with a reading is out of capacity.")
                .font(.caption).foregroundStyle(Theme.inkMute)
        }
        .font(.subheadline)
        .themeRows()
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.ink)
            Text(label).font(.caption2).foregroundStyle(Theme.inkSoft).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
    }
}

/// The Rotation Log, folded as the page folds it.
private struct RotationLogSection: View {
    let events: [RotationEvent]
    @Binding var expanded: Bool
    let open: (Int) -> Void

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(events) { event in row(event) }
            } label: {
                HStack {
                    Text("Rotation log").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text(verbatim: "\(events.count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.inkMute)
                }
            }
            .tint(Theme.inkMute)
            .accessibilityIdentifier("inference.log")
        }
        .themeRows()
    }

    private func row(_ event: RotationEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(verbatim: "\(Format.age(event.at)) ago")
                    .accessibilityLabel(event.at.formatted(.relative(presentation: .named)))
                Text("·")
                Text(event.source == "automatic" ? "automatic" : "manual")
                if let reason = event.reason { Text("·"); Text(reason) }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.inkMute)
            Text(verbatim: "\(event.from.label) → \(event.to.label)").font(.subheadline).foregroundStyle(Theme.ink)
            if let session = event.sessionID {
                Button("Session #\(session)") { open(session) }
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).buttonStyle(.borderless)
            } else if let by = event.triggeredBy {
                Text(by).font(.caption).foregroundStyle(Theme.inkSoft)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inference.log.\(event.id)")
    }
}

/// The Pi tab's OpenRouter key card, read-only: the page sets and deletes the key.
private struct OpenRouterKeyCard: View {
    let key: OpenRouterKeyState?

    var body: some View {
        Section {
            if let key {
                HStack {
                    Text("OpenRouter API key").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(key.present ? "Set" : "Not set")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2.5)
                        .foregroundStyle(key.present ? Theme.success : Theme.inkSoft)
                        .background((key.present ? Theme.success : Theme.inkMute).opacity(0.14), in: Capsule())
                        .accessibilityIdentifier("inference.openrouter.state")
                }
                LabeledContent("Variable") { Text(key.variable).font(Theme.mono) }
                LabeledContent("Resolves from", value: key.present ? (key.providerBadge ?? key.providerLabel ?? "—") : "—")
                LabeledContent("Fingerprint (SHA-256)") { Text(key.fingerprint ?? "—").font(Theme.mono) }
                LabeledContent("Last set from the web page", value: key.lastWrite.map { "\(InferenceFormat.ago($0.at)) (\($0.action))" } ?? "never")
                if let path = key.path {
                    LabeledContent("Address") { Text(verbatim: "\(path) in \(key.projectID ?? "?") (\(key.location ?? "?"))").font(Theme.mono).multilineTextAlignment(.trailing) }
                }
                if !key.writable, let reason = key.writeReason {
                    Text("Zimmer cannot write to the store yet: \(reason).").font(.caption).foregroundStyle(Theme.warning)
                }
            } else {
                Text("The key's state did not come back.").font(.subheadline).foregroundStyle(Theme.inkSoft)
            }
        } header: {
            Text("OpenRouter").themeLabel()
        } footer: {
            Text("Pi authenticates per request from a provider key in the session environment. The key is set and deleted on the web page's Inference tab; nothing here, and no endpoint behind it, returns the stored value.")
                .font(.caption).foregroundStyle(Theme.inkMute)
                .accessibilityIdentifier("inference.openrouter.note")
        }
        .font(.subheadline)
        .themeRows()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inference.openrouter")
    }
}

/// The Add account form: email, priority, and for Codex an optional API key.
private struct AddAccountSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let runtime: String
    let label: String
    let added: (InferenceAccount) async -> Void
    @State private var email = ""
    @State private var priority = "0"
    @State private var apiKey = ""
    @State private var error: String?
    @State private var submitting = false

    private var isCodex: Bool { runtime == InferenceReport.codex }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("account@example.com", text: $email)
                        .keyboardType(.emailAddress).textContentType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("inference.add.email")
                } header: {
                    Text("Email")
                }
                Section {
                    TextField("0", text: $priority).keyboardType(.numberPad)
                        .accessibilityIdentifier("inference.add.priority")
                } header: {
                    Text("Priority")
                } footer: {
                    Text("Lower numbers are preferred when rotating.")
                }
                if isCodex {
                    Section {
                        SecureField("sk-... (leave blank to authenticate via OAuth)", text: $apiKey)
                            .font(Theme.mono)
                            .accessibilityIdentifier("inference.add.apiKey")
                    } header: {
                        Text("API key (optional)")
                    } footer: {
                        Text("Provide an OpenAI API key to create a ready-to-use account. Leave blank to add an OAuth account that you authenticate afterward.")
                    }
                } else {
                    Section {
                        Text("The account is created without credentials. After adding it, authenticate it to capture OAuth tokens.")
                            .font(.caption).foregroundStyle(Theme.inkSoft)
                    }
                }
                if let error {
                    Section { Text(error).font(.caption).foregroundStyle(Theme.danger).accessibilityIdentifier("inference.add.error") }
                }
            }
            .navigationTitle("Add \(label) account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add account") { Task { await submit() } }
                        .disabled(submitting || email.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("inference.add.submit")
                }
            }
        }
    }

    private func submit() async {
        guard let priorityValue = Int(priority.trimmingCharacters(in: .whitespaces)) else {
            error = "Priority must be a whole number"
            return
        }
        submitting = true
        defer { submitting = false }
        do {
            let change = try await app.api.addInferenceAccount(runtime: runtime, email: email.trimmingCharacters(in: .whitespaces), priority: priorityValue,
                                                               apiKey: isCodex ? apiKey : nil)
            Haptics.success()
            dismiss()
            await added(change.account)
        } catch {
            self.error = (error as? ZimmerError ?? .transport(error)).userMessage
            Haptics.failure()
        }
    }
}
