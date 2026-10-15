import SwiftUI
import ZimmerKit

/// Settings → API keys, as the app: the deployment's MCP connections (this phone among
/// them), its keys, and a form to mint one. Every write asks first, as the page's
/// `turbo_confirm` does, and a refusal is shown under the row it answers, in the server's
/// words; the rows stay as the server lists them.
struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    /// Revoking this phone's own connection signs the app out; the caller closes Settings.
    var onSignedOut: () -> Void = {}

    @State private var grants: [OAuthGrant]?
    @State private var keys: [APIKey]?
    @State private var loadError: ZimmerError?
    /// A refusal under the row it answers, keyed by the row ("grant.4", "key.2", "new").
    @State private var errors: [String: String] = [:]
    @State private var busy: Set<String> = []
    @State private var confirming: Confirmation?

    // The form, as it holds a key before it is minted.
    @State private var newName = ""
    @State private var newGrant = APIKey.apiGrant
    /// The key just minted, with the one copy of its token. State of this screen alone, so
    /// leaving it is the last of the token.
    @State private var minted: MintedAPIKey?

    /// What a write asks before it runs.
    private enum Confirmation: Identifiable {
        case revokeGrant(OAuthGrant), raiseGrant(OAuthGrant), revokeKey(APIKey)

        var id: String {
            switch self {
            case let .revokeGrant(grant): return "grant.\(grant.id).revoke"
            case let .raiseGrant(grant): return "grant.\(grant.id).raise"
            case let .revokeKey(key): return "key.\(key.id).revoke"
            }
        }

        var title: String {
            switch self {
            case .revokeGrant: return "Revoke this connection?"
            case .raiseGrant: return "Let it act on your behalf?"
            case .revokeKey: return "Revoke this key?"
            }
        }

        var message: String {
            switch self {
            case let .revokeGrant(grant): return grant.revokeConfirmation
            case let .raiseGrant(grant): return grant.raiseConfirmation
            case let .revokeKey(key): return key.revokeConfirmation
            }
        }

        var action: String {
            switch self {
            case .revokeGrant, .revokeKey: return "Revoke"
            case .raiseGrant: return "Let it act on my behalf"
            }
        }

        var role: ButtonRole? {
            switch self {
            case .revokeGrant, .revokeKey: return .destructive
            case .raiseGrant: return nil
            }
        }
    }

    var body: some View {
        Form {
            Group {
                if let loadError {
                    Section {
                        ErrorBanner(error: loadError).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                            .accessibilityIdentifier("account.load.error")
                        Button("Try again") { Task { await load() } }
                            .accessibilityIdentifier("account.retry")
                    }
                } else if grants == nil || keys == nil {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading…").font(.subheadline).foregroundStyle(Theme.inkSoft)
                        }
                        .accessibilityIdentifier("account.loading")
                    }
                }
                if let grants { connections(grants) }
                if let keys {
                    keyList(keys)
                    createKey
                }
            }
            .themeRows()
        }
        .themeGround()
        .navigationTitle("API keys & connections")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            confirming?.title ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { confirmation in
            Button(confirmation.action, role: confirmation.role) { Task { await run(confirmation) } }
                .accessibilityIdentifier("account.confirm")
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    // MARK: - MCP connections

    private func connections(_ grants: [OAuthGrant]) -> some View {
        Section {
            if grants.isEmpty {
                Text("No OAuth connections.").font(.subheadline).foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("account.grants.none")
            }
            ForEach(grants) { grant in
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(grant.clientLabel).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                        FlowLayout(spacing: 6, rowSpacing: 6) {
                            badge(grant.isRevoked ? "Revoked" : "Active", tone: grant.isRevoked ? .danger : .success)
                            if grant.current { badge("This phone", tone: .accent) }
                            badge(grant.privilegeLabel, tone: grant.actsAsYou ? .warning : .plain)
                            badge(grant.registrationLabel, tone: .plain)
                        }
                        detail("Approved by", grant.userEmail)
                        detail("Last used", grant.lastUsedAt.map(WebDates.ago) ?? "never")
                        detail("Approved", WebDates.stamp(grant.createdAt))
                        if let changed = grant.scopeChangedAt {
                            detail("Level set", WebDates.stamp(changed) + (grant.scopeChangeLabel.map { " — \($0)" } ?? ""))
                        }
                        if let revoked = grant.revokedAt {
                            detail("Revoked", WebDates.stamp(revoked) + (grant.revocationReason.map { " — \($0)" } ?? ""))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("account.grant.\(grant.id)")
                    if !grant.isRevoked {
                        HStack(spacing: 8) {
                            if grant.actsAsYou {
                                Button("Make relay only") { Task { await setPrivilege(grant, actsAsYou: false) } }
                                    .accessibilityIdentifier("account.grant.\(grant.id).privilege")
                            } else {
                                Button("Let it act on my behalf") { confirming = .raiseGrant(grant) }
                                    .tint(Theme.warning)
                                    .accessibilityIdentifier("account.grant.\(grant.id).privilege")
                            }
                            Button("Revoke", role: .destructive) { confirming = .revokeGrant(grant) }
                                .accessibilityIdentifier("account.grant.\(grant.id).revoke")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(busy.contains("grant.\(grant.id)"))
                    }
                    if let message = errors["grant.\(grant.id)"] { refusal(message) }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("MCP connections")
        } footer: {
            Text("Clients that connected to /mcp over OAuth instead of with a key — this phone, another phone, a Claude.ai custom connector. The deployment's whole list, whoever approved each one. A connection that acts on your behalf has the messages it sends recorded as written by the person who approved it; a relay only connection's are recorded as the assistant's. Revoking one refuses it from the next request on, and it has to be approved again to reconnect.")
        }
    }

    // MARK: - Keys

    private func keyList(_ keys: [APIKey]) -> some View {
        Section {
            if keys.isEmpty {
                Text("No keys. Nothing can call the API until one exists — set \(APIKey.envVar) or create one below.")
                    .font(.subheadline).foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("account.keys.none")
            }
            ForEach(keys) { key in
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                        FlowLayout(spacing: 6, rowSpacing: 6) {
                            badge(key.statusLabel, tone: key.isRevoked ? .danger : key.isRetired ? .plain : .success)
                            badge(key.sourceLabel, tone: .plain)
                            if key.isQuickRouter { badge("Quick Router only", tone: .info) }
                            if let app = key.externalApp { badge("Zimmer plugin: \(app.name)", tone: .plain) }
                            if key.agentSessionsUseIt { badge("Agent sessions use this key", tone: .warning) }
                        }
                        detail("Fingerprint", key.fingerprint, mono: true)
                        detail("Last used", key.lastUsedAt.map(WebDates.ago) ?? "never")
                        detail("Created", WebDates.stamp(key.createdAt))
                        if let revoked = key.revokedAt { detail("Revoked", WebDates.stamp(revoked)) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("account.key.\(key.id)")
                    HStack {
                        if key.isRevoked {
                            Button("Restore") { Task { await restore(key) } }
                                .accessibilityIdentifier("account.key.\(key.id).restore")
                        } else {
                            Button("Revoke", role: .destructive) { confirming = .revokeKey(key) }
                                .accessibilityIdentifier("account.key.\(key.id).revoke")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy.contains("key.\(key.id)"))
                    if let message = errors["key.\(key.id)"] { refusal(message) }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Keys")
        } footer: {
            Text("The deployment's keys for the REST API and /mcp. Keys from the \(APIKey.envVar) variable are listed under their fingerprint — the first eight characters of their SHA-256. Agent sessions carry the whole variable in their environment, so every entry there is within an agent's reach; only a minted key is not. Last used is recorded to the minute.")
        }
    }

    // MARK: - Create a key

    private var createKey: some View {
        Section {
            if let minted {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Created \(minted.key.name)").font(.subheadline.weight(.medium))
                    Text("Copy it now. Zimmer keeps only a digest of it, so this is the one time it can be shown.")
                        .font(.caption)
                    Text(verbatim: minted.token)
                        .font(Theme.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityIdentifier("account.key.token")
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = minted.token }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("account.key.token.copy")
                    if minted.key.isQuickRouter {
                        Text("Paste it into the Zimmer extension's options, with this instance's URL. It starts Quick Router sessions and cannot read anything back.")
                            .font(.caption)
                    }
                }
                .foregroundStyle(Theme.success)
                .padding(.vertical, 4)
            }
            HStack(spacing: 8) {
                TextField("Name, e.g. laptop scripts", text: $newName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { Task { await mint() } }
                    .accessibilityIdentifier("account.key.new.name")
                Button("Create key") { Task { await mint() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || busy.contains("new"))
                    .accessibilityIdentifier("account.key.new")
            }
            Picker("What it opens", selection: $newGrant) {
                Text("Full API").tag(APIKey.apiGrant)
                Text("Quick Router only").tag(APIKey.quickRouterGrant)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("account.key.new.grant")
            if let message = errors["new"] { refusal(message) }
        } header: {
            Text("Create a key")
        } footer: {
            Text("Name it after whatever will hold it — the name is what the log prints. Full API opens the REST API and /mcp, everything a script or an MCP client does. Quick Router only is for the browser extension: it starts a Quick Router session from a page and reads nothing, and is refused everywhere else.")
        }
    }

    // MARK: - Pieces

    private enum BadgeTone { case success, danger, warning, info, accent, plain }

    /// The page's pill badges, in its colours.
    private func badge(_ text: String, tone: BadgeTone) -> some View {
        let colors: (text: Color, fill: Color)
        switch tone {
        case .success: colors = (Theme.status(.running).text, Theme.status(.running).fill)
        case .danger: colors = (Theme.danger, Theme.danger.opacity(0.12))
        case .warning: colors = (Theme.banner(.warning).text, Theme.banner(.warning).fill)
        case .info: colors = (Theme.banner(.info).text, Theme.banner(.info).fill)
        case .accent: colors = (Theme.accent, Theme.well)
        case .plain: colors = (Theme.inkSoft, Theme.well)
        }
        return Text(text)
            .font(Theme.label())
            .foregroundStyle(colors.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(colors.fill, in: Capsule())
    }

    private func detail(_ term: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(term).font(.caption).foregroundStyle(Theme.inkMute)
            Text(verbatim: value).font(mono ? Theme.mono : .caption).foregroundStyle(Theme.inkSoft)
        }
    }

    /// The server's refusal, in its words, under the row it answers.
    private func refusal(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(Theme.danger)
            .accessibilityIdentifier("account.error")
    }

    // MARK: - Reads and writes

    private func load() async {
        let api = model.api
        do {
            async let grants = api.oauthGrants()
            async let keys = api.apiKeys()
            self.grants = try await grants
            self.keys = try await keys
            loadError = nil
        } catch {
            let error = error as? ZimmerError ?? .transport(error)
            model.noteError(error)
            loadError = error
        }
    }

    private func run(_ confirmation: Confirmation) async {
        switch confirmation {
        case let .revokeGrant(grant): await revoke(grant)
        case let .raiseGrant(grant): await setPrivilege(grant, actsAsYou: true)
        case let .revokeKey(key): await revoke(key)
        }
    }

    /// One write, with the row's buttons held while it runs; the server's answer replaces
    /// the row, and a refusal is shown under it with the row unchanged.
    private func write(_ row: String, _ action: () async throws -> Void) async {
        busy.insert(row)
        errors[row] = nil
        do {
            try await action()
            Haptics.success()
        } catch {
            let error = error as? ZimmerError ?? .transport(error)
            model.noteError(error)
            errors[row] = error.userMessage
            Haptics.failure()
        }
        busy.remove(row)
    }

    private func setPrivilege(_ grant: OAuthGrant, actsAsYou: Bool) async {
        await write("grant.\(grant.id)") {
            let answered = try await model.api.setGrantPrivilege(grant.id, actsAsYou: actsAsYou)
            replace(answered)
        }
    }

    private func revoke(_ grant: OAuthGrant) async {
        var signedOut = false
        await write("grant.\(grant.id)") {
            let revocation = try await model.api.revokeGrant(grant.id)
            replace(revocation.grant)
            signedOut = revocation.signedOut
        }
        // The server refuses this phone's token from its next request on.
        if signedOut {
            await model.signOut()
            onSignedOut()
        }
    }

    private func revoke(_ key: APIKey) async {
        await write("key.\(key.id)") { replace(try await model.api.revokeAPIKey(key.id)) }
    }

    private func restore(_ key: APIKey) async {
        await write("key.\(key.id)") { replace(try await model.api.restoreAPIKey(key.id)) }
    }

    private func mint() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !busy.contains("new") else { return }
        await write("new") {
            let answered = try await model.api.mintAPIKey(name: name, grant: newGrant)
            minted = answered
            newName = ""
            // The server lists active keys newest first; so does the row until the next read.
            keys?.insert(answered.key, at: 0)
        }
    }

    private func replace(_ grant: OAuthGrant) {
        guard let index = grants?.firstIndex(where: { $0.id == grant.id }) else { return }
        grants?[index] = grant
    }

    private func replace(_ key: APIKey) {
        guard let index = keys?.firstIndex(where: { $0.id == key.id }) else { return }
        keys?[index] = key
    }
}

/// Dates as Settings → API keys prints them. Format styles rather than formatters: value
/// types, so a static one is concurrency-safe.
enum WebDates {
    /// "2026-10-14 17:22 UTC", the page's `strftime("%Y-%m-%d %H:%M UTC")`.
    static func stamp(_ date: Date) -> String {
        let style = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits) UTC",
            timeZone: .gmt,
            calendar: Calendar(identifier: .gregorian)
        )
        return date.formatted(style)
    }

    /// "3 days ago", the page's `time_ago_in_words` with its "ago".
    static func ago(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}
