import SwiftUI
import ZimmerKit

/// The three sections of the Settings screen that are the web page's: a scroll target.
enum SettingsSection: String, Hashable {
    case defaults, experimental, mcpApps
}

/// A fixture launch's request to open Settings, at a section if it named one. Identifiable so
/// a sheet can be presented on it; a fresh id each time, so asking twice opens twice.
struct SettingsOpening: Identifiable, Hashable {
    let id = UUID()
    var section: SettingsSection?
    /// Open with API keys & connections pushed over it.
    var account = false
}

/// The web page's Settings, as the app can write them: its Sign-in card and a row into
/// API keys & connections (`/api/v1/me`, `/oauth_grants`, `/api_keys`), the global session
/// defaults, the experimental toggles and MCP Apps (`/api/v1/app_settings`), then the
/// phone's own rows and the page's Deployment Information. Each section saves on its own,
/// as each of the page's forms submits on its own: the toggles at once, the defaults and
/// MCP Apps from their Save.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// The section the screen scrolls to as it opens, for `ios/bin/ui-test`'s photographs.
    var opensAt: SettingsSection? = nil
    /// Open with API keys & connections pushed over it, for the same photographs.
    var opensAccount = false

    @State private var notificationStatus = "…"
    @ObservedObject private var push = PushCoordinator.shared
    /// Who the token is, the Sign-in card and the deployment; nil until read.
    @State private var account: Account?
    @State private var accountError: ZimmerError?
    @State private var showingAccount = false
    /// The fixture's push, made once: the task runs again each time the child pops.
    @State private var openedAccountForFixture = false
    @State private var confirmingSignOutEverywhere = false
    @State private var signingOutEverywhere = false
    @State private var signOutEverywhereError: String?
    /// The server's row; nil until it has been read.
    @State private var settings: AppSettings?
    @State private var loadError: ZimmerError?

    // Session Defaults, as the form holds them before a save.
    @State private var runtime = ""
    @State private var modelID = ""
    @State private var savingDefaults = false
    @State private var defaultsError: String?

    /// A toggle flipped and not yet answered: drawn as flipped, and back if the server refused.
    @State private var pendingExperimental: [String: Bool] = [:]
    @State private var experimentalErrors: [String: String] = [:]

    // MCP Apps, as the form holds them before a save.
    @State private var mcpAppsEnabled = false
    @State private var mcpAllowed: Set<String> = []
    @State private var savingMcpApps = false
    @State private var mcpAppsError: String?
    @State private var mcpAppsSaved = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Group {
                        signInCard
                        Section {
                            NavigationLink { AccountView(onSignedOut: { dismiss() }) } label: {
                                Label("API keys & connections", systemImage: "key")
                            }
                            .accessibilityIdentifier("settings.account")
                        } footer: {
                            Text("The deployment's API keys, and every client connected to /mcp over OAuth — this phone among them.")
                        }
                        if model.hasEdge {
                            Section {
                                LabeledContent("Expires") {
                                    if let expiry = model.edgeExpiry { Text(expiry, style: .relative) } else { Text("Not signed in") }
                                }
                                Button("Sign in to the edge again") { Task { await model.signInToEdge() } }
                                    .accessibilityIdentifier("settings.edge.signin")
                            } header: {
                                Text("Edge sign-in")
                            } footer: {
                                Text("The app host sits behind an access proxy with its own sign-in. It renews itself a day before it expires.")
                            }
                        }
                        serverSettings
                        Section {
                            LabeledContent("Status", value: notificationStatus)
                                .accessibilityIdentifier("settings.notifications")
                            if let registration = push.registration {
                                LabeledContent("This phone", value: registration)
                                    .accessibilityIdentifier("settings.notifications.registration")
                            }
                            if notificationStatus == "Not asked yet" {
                                Button("Turn on notifications") {
                                    Task {
                                        await PushCoordinator.shared.enable()
                                        await loadNotificationStatus()
                                    }
                                }
                            } else if notificationStatus == "On" {
                                Button("Register this phone again") {
                                    Task { await push.enable() }
                                }
                                .accessibilityIdentifier("settings.notifications.reregister")
                            }
                        } header: {
                            Text("Notifications")
                        } footer: {
                            Text("Zimmer pushes when a session needs your input, finishes, or fails. Change it in iOS Settings → Zimmer.")
                        }
                        deploymentInformation
                    }
                    .themeRows()
                }
                .themeGround()
                .navigationDestination(isPresented: $showingAccount) { AccountView(onSignedOut: { dismiss() }) }
                .task { await loadNotificationStatus() }
                .task { await loadAccount() }
                .task {
                    guard opensAccount, !openedAccountForFixture else { return }
                    openedAccountForFixture = true
                    // After the stack has laid out, or the push can be dropped.
                    try? await Task.sleep(for: .milliseconds(300))
                    showingAccount = true
                }
                .task {
                    await loadSettings()
                    guard let opensAt, settings != nil else { return }
                    // After the layout that adds the sections, or the scroll can miss.
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo(opensAt, anchor: .top)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    // MARK: - The Sign-in card and Deployment Information

    /// The page's Sign-in card: who this phone is signed in as and how it may act, the
    /// authenticator and recovery codes where the server tells the app them (only a sign-in
    /// acting as you is told), and the two sign-outs. The host rows are the phone's own.
    private var signInCard: some View {
        Section {
            HStack {
                Text("Server").foregroundStyle(Theme.inkSoft)
                Spacer()
                Text(model.signedInOrigins?.web.host ?? "—")
                    .accessibilityIdentifier("settings.server")
            }
            if let origins = model.signedInOrigins, origins.isSplit {
                LabeledContent("App host", value: origins.api.host ?? "—")
            }
            if let account {
                (Text("Signed in as ") + Text(account.me.email ?? "—").fontWeight(.medium))
                    .accessibilityIdentifier("settings.signin.email")
                Text(account.me.actsAsYou
                     ? "This connection acts on your behalf: what it sends to a session is recorded as written by you."
                     : "This connection is relay only: what it sends to a session is recorded as the assistant's.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("settings.signin.privilege")
                if let card = account.webSignIn, let enrolled = card.totpEnrolledAt {
                    Text("Authenticator set up \(WebDates.ago(enrolled))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSoft)
                        .accessibilityIdentifier("settings.signin.totp")
                    if let line = card.recoveryCodesLine {
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(Theme.inkSoft)
                            .accessibilityIdentifier("settings.signin.recovery")
                    }
                }
            } else if let accountError {
                Text(accountError.userMessage).font(.caption).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("settings.signin.error")
                Button("Try again") { Task { await loadAccount() } }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading who you are…").font(.subheadline).foregroundStyle(Theme.inkSoft)
                }
                .accessibilityIdentifier("settings.signin.loading")
            }
            Button("Sign out", role: .destructive) {
                Task {
                    await model.signOut()
                    dismiss()
                }
            }
            .accessibilityIdentifier("settings.signout")
            Button("Sign out everywhere", role: .destructive) { confirmingSignOutEverywhere = true }
                .disabled(account == nil || signingOutEverywhere)
                .accessibilityIdentifier("settings.signin.everywhere")
            if let signOutEverywhereError {
                Text(signOutEverywhereError).font(.caption).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("settings.signin.everywhere.error")
            }
        } header: {
            Text("Sign-in")
        } footer: {
            Text("Signing out revokes this phone's connection on the server. Signing out everywhere also ends every browser signed in as you; this phone has to sign in again afterwards.")
        }
        .confirmationDialog("Sign out everywhere?", isPresented: $confirmingSignOutEverywhere, titleVisibility: .visible) {
            Button("Sign out everywhere", role: .destructive) { Task { await signOutEverywhere() } }
        } message: {
            Text("Sign out every browser signed in as \(account?.me.email ?? "you"), this phone included?")
        }
    }

    /// The page's Deployment Information — the commit the server booted from and its
    /// environment — and, under it, this app's own build.
    private var deploymentInformation: some View {
        Section {
            if let deployment = account?.deployment {
                LabeledContent("Commit SHA") {
                    Text(verbatim: deployment.git.commitShort).font(Theme.mono)
                        .accessibilityIdentifier("settings.deployment.sha")
                }
                .contextMenu {
                    Button("Copy full SHA", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = deployment.git.commitSha
                    }
                    .accessibilityIdentifier("settings.deployment.sha.copy")
                }
                LabeledContent("Branch") {
                    Text(verbatim: deployment.git.branch).font(Theme.mono)
                        .accessibilityIdentifier("settings.deployment.branch")
                }
                if let date = deployment.git.commitDate {
                    LabeledContent("Commit Date") {
                        Text(verbatim: date).accessibilityIdentifier("settings.deployment.date")
                    }
                }
                LabeledContent("Rails Environment") {
                    Text(verbatim: deployment.environment.railsEnv).accessibilityIdentifier("settings.deployment.environment")
                }
                LabeledContent("Ruby Version", value: deployment.environment.rubyVersion)
                LabeledContent("Rails Version", value: deployment.environment.railsVersion)
            } else {
                Text(accountError.map { "Not read: \($0.userMessage)" } ?? "Reading the deployment…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
            LabeledContent("App version", value: Self.version)
            Text(model.buildTarget.summary)
                .font(Theme.mono)
                .foregroundStyle(Theme.inkSoft)
                .accessibilityIdentifier("build.target")
        } header: {
            Text("Deployment Information")
        } footer: {
            Text("The server this phone talks to, for troubleshooting: the commit it booted from (long-press it to copy the whole SHA) and its environment, then this app's own build.")
        }
    }

    private func loadAccount() async {
        do {
            account = try await model.api.account()
            accountError = nil
        } catch {
            let error = error as? ZimmerError ?? .transport(error)
            model.noteError(error)
            accountError = error
        }
    }

    /// The server ends every web sign-in as this person and revokes this phone's own
    /// connection with them, so the app signs itself out once it has answered.
    private func signOutEverywhere() async {
        signingOutEverywhere = true
        signOutEverywhereError = nil
        do {
            _ = try await model.api.signOutEverywhere()
            await model.signOut()
            dismiss()
        } catch {
            let error = error as? ZimmerError ?? .transport(error)
            model.noteError(error)
            signOutEverywhereError = error.userMessage
            Haptics.failure()
        }
        signingOutEverywhere = false
    }

    // MARK: - The web page's sections

    /// The row's three sections once it has been read; a loading row or the error until then.
    @ViewBuilder
    private var serverSettings: some View {
        if let settings {
            sessionDefaults(settings)
            experimental(settings)
            mcpApps(settings)
        } else if let loadError {
            Section {
                ErrorBanner(error: loadError).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                Button("Try again") { Task { await loadSettings() } }
                    .accessibilityIdentifier("settings.retry")
            }
        } else {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading settings…").font(.subheadline).foregroundStyle(Theme.inkSoft)
                }
                .accessibilityIdentifier("settings.loading")
            }
        }
    }

    private func sessionDefaults(_ settings: AppSettings) -> some View {
        Section {
            banner(settings.sessionDefaultsBanner, warning: false, tinted: settings.sessionDefaults.isOverridden)
                .accessibilityIdentifier("settings.defaults.banner")
            Picker("Runtime", selection: runtimeSelection) {
                ForEach(settings.runtimes) { entry in Text(entry.label).tag(entry.id) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.defaults.runtime")
            Picker("Model", selection: $modelID) {
                ForEach(settings.models(for: runtime), id: \.self) { model in Text(verbatim: model).tag(model) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.defaults.model")
            Button {
                Task { await saveDefaults(settings) }
            } label: {
                HStack {
                    Text("Save session defaults")
                    if savingDefaults {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(!defaultsChanged(settings) || savingDefaults)
            .accessibilityIdentifier("settings.defaults.save")
            if let defaultsError {
                Text(defaultsError).font(.caption).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("settings.defaults.error")
            }
        } header: {
            Text("Session Defaults")
        } footer: {
            Text("The base agent runtime and model used when nothing more specific is set — when neither the new-session form nor an agent root's roots.json entry pins its own runtime and model. Roots and per-session choices always override this. To return to the built-in default, pick \(settings.runtimeLabel(settings.sessionDefaults.builtIn.runtime)) / \(settings.sessionDefaults.builtIn.model) and save.")
        }
        .id(SettingsSection.defaults)
    }

    private func experimental(_ settings: AppSettings) -> some View {
        Section {
            ForEach(settings.experimental) { setting in
                let on = pendingExperimental[setting.key] ?? setting.enabled
                VStack(alignment: .leading, spacing: 10) {
                    banner(setting.statusLine(on: on), warning: on != setting.defaultEnabled, tinted: false)
                        .accessibilityIdentifier("settings.experimental.\(setting.key).status")
                    Toggle(isOn: Binding(get: { on }, set: { value in Task { await setExperimental(setting, to: value) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(setting.title).font(.subheadline).foregroundStyle(Theme.ink)
                            Text(setting.description).font(.caption).foregroundStyle(Theme.inkSoft)
                        }
                    }
                    .tint(Theme.accent)
                    .disabled(pendingExperimental[setting.key] != nil)
                    .accessibilityIdentifier("settings.experimental.\(setting.key)")
                    if let message = experimentalErrors[setting.key] {
                        Text(message).font(.caption).foregroundStyle(Theme.danger)
                            .accessibilityIdentifier("settings.experimental.\(setting.key).error")
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Experimental")
        } footer: {
            Text("Features that are not yet considered stable. Each one says whether it is on by default; change one only if you know you need to. A switch saves as it is flipped.")
        }
        .id(SettingsSection.experimental)
    }

    private func mcpApps(_ settings: AppSettings) -> some View {
        Section {
            Toggle(isOn: $mcpAppsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Render MCP App views").font(.subheadline).foregroundStyle(Theme.ink)
                    Text("The master switch. With it off nothing renders, whatever is ticked below.")
                        .font(.caption).foregroundStyle(Theme.inkSoft)
                }
            }
            .tint(Theme.accent)
            .onChange(of: mcpAppsEnabled) { _, _ in mcpAppsSaved = false }
            .accessibilityIdentifier("settings.mcpapps.enabled")
            VStack(alignment: .leading, spacing: 2) {
                Text("Servers allowed to render views").font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                Text("Remote MCP servers from the catalog. A stdio server cannot be opted in — Zimmer reads a fragment over the server's own HTTP endpoint, and there is none to read.")
                    .font(.caption).foregroundStyle(Theme.inkSoft)
            }
            if settings.mcpApps.eligibleServers.isEmpty {
                Text("No remote MCP servers in the catalog.").font(.subheadline).foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("settings.mcpapps.servers.none")
            } else {
                ForEach(settings.mcpApps.eligibleServers) { server in
                    let ticked = mcpAllowed.contains(server.name)
                    Button {
                        if ticked { mcpAllowed.remove(server.name) } else { mcpAllowed.insert(server.name) }
                        mcpAppsSaved = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.title).foregroundStyle(Theme.ink)
                                Text(verbatim: server.name).font(Theme.mono).foregroundStyle(Theme.inkSoft)
                            }
                            Spacer()
                            if ticked {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.mcpapps.server.\(server.name)")
                    .accessibilityAddTraits(ticked ? .isSelected : [])
                }
            }
            Button {
                Task { await saveMcpApps() }
            } label: {
                HStack {
                    Text("Save MCP Apps settings")
                    Spacer()
                    if savingMcpApps {
                        ProgressView().controlSize(.small)
                    } else if mcpAppsSaved {
                        Text("Saved").font(.caption).foregroundStyle(Theme.success)
                            .accessibilityIdentifier("settings.mcpapps.saved")
                    }
                }
            }
            .disabled(savingMcpApps)
            .accessibilityIdentifier("settings.mcpapps.save")
            if let mcpAppsError {
                Text(mcpAppsError).font(.caption).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("settings.mcpapps.error")
            }
        } header: {
            Text("MCP Apps")
        } footer: {
            Text("When an agent calls an MCP tool that declares a ui:// view, render that view inline in the session transcript. The view is HTML written by whoever runs the MCP server and it runs in your browser, sandboxed — so it is off by default, and each server has to be named here before anything of its renders.")
        }
        .id(SettingsSection.mcpApps)
    }

    /// The page's status banner: its amber when `warning`, its indigo when `tinted`, its
    /// gray otherwise.
    private func banner(_ text: String, warning: Bool, tinted: Bool) -> some View {
        let colors: Theme.StatusColors? = warning ? Theme.banner(.warning) : tinted ? Theme.banner(.info) : nil
        return Text(text)
            .font(.subheadline)
            .foregroundStyle(colors?.text ?? Theme.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(colors?.fill ?? Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Session Defaults

    /// Picking a runtime resets the model to that runtime's default, as the page's select
    /// does, so an incompatible pairing cannot be chosen.
    private var runtimeSelection: Binding<String> {
        Binding(
            get: { runtime },
            set: { picked in
                guard picked != runtime else { return }
                runtime = picked
                modelID = settings?.runtime(picked)?.defaultModel ?? ""
            }
        )
    }

    /// Something to save: a different pair, or the built-in pair while an override is stored —
    /// the web page stores the built-in pair as an override when it is picked there, and the
    /// phone is where it gets cleared.
    private func defaultsChanged(_ settings: AppSettings) -> Bool {
        let defaults = settings.sessionDefaults
        if runtime != defaults.runtime || modelID != defaults.model { return true }
        let overridden = defaults.runtimeOverridden || defaults.modelOverridden
        return overridden && runtime == defaults.builtIn.runtime && modelID == defaults.builtIn.model
    }

    /// The built-in pair is sent as no override at all, so picking it clears the override
    /// rather than storing a copy of the default.
    private func saveDefaults(_ settings: AppSettings) async {
        let builtIn = settings.sessionDefaults.builtIn
        let clearing = runtime == builtIn.runtime && modelID == builtIn.model
        savingDefaults = true
        defaultsError = nil
        do {
            let answered = try await model.api.updateAppSettings(AppSettingsChange(defaultRuntime: clearing ? "" : runtime, defaultModel: clearing ? "" : modelID))
            apply(answered)
            Haptics.success()
        } catch {
            let error = error as? ZimmerError ?? .transport(error)
            model.noteError(error)
            defaultsError = error.userMessage
            Haptics.failure()
        }
        savingDefaults = false
    }

    // MARK: - Experimental

    /// A switch saves at once; the status line follows the server's answer, and a refusal
    /// puts the switch back where it was.
    private func setExperimental(_ setting: AppSettings.Experimental, to enabled: Bool) async {
        pendingExperimental[setting.key] = enabled
        experimentalErrors[setting.key] = nil
        do {
            settings = try await model.api.updateAppSettings(AppSettingsChange(experimental: [setting.key: enabled]))
            Haptics.success()
        } catch {
            let error = error as? ZimmerError ?? .transport(error)
            model.noteError(error)
            experimentalErrors[setting.key] = error.userMessage
            Haptics.failure()
        }
        pendingExperimental[setting.key] = nil
    }

    // MARK: - MCP Apps

    /// A refusal is shown under the Save, and the switch and ticks stay as they were set.
    private func saveMcpApps() async {
        guard let settings else { return }
        savingMcpApps = true
        mcpAppsError = nil
        // In the catalog's order, as the page submits its checkboxes.
        let allowed = settings.mcpApps.eligibleServers.map(\.name).filter(mcpAllowed.contains)
        do {
            let answered = try await model.api.updateAppSettings(AppSettingsChange(mcpAppsEnabled: mcpAppsEnabled, mcpAppsAllowedServers: allowed))
            apply(answered)
            mcpAppsSaved = true
            Haptics.success()
        } catch {
            let error = error as? ZimmerError ?? .transport(error)
            model.noteError(error)
            mcpAppsError = error.userMessage
            Haptics.failure()
        }
        savingMcpApps = false
    }

    // MARK: - Loading

    private func loadSettings() async {
        do {
            apply(try await model.api.appSettings())
            loadError = nil
        } catch {
            let error = error as? ZimmerError ?? .transport(error)
            model.noteError(error)
            loadError = error
        }
    }

    /// The row as the server answered it, and the forms set from it.
    private func apply(_ answered: AppSettings) {
        settings = answered
        runtime = answered.sessionDefaults.runtime
        modelID = answered.sessionDefaults.model
        mcpAppsEnabled = answered.mcpApps.enabled
        mcpAllowed = Set(answered.mcpApps.allowedServers)
    }

    private func loadNotificationStatus() async {
        switch await PushCoordinator.shared.authorizationStatus() {
        case .authorized, .provisional, .ephemeral: notificationStatus = "On"
        case .denied: notificationStatus = "Off"
        case .notDetermined: notificationStatus = "Not asked yet"
        @unknown default: notificationStatus = "Unknown"
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
