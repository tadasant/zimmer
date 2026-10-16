import SwiftUI
import ZimmerKit

/// The web UI's Health page, section for section in its order: the two site-wide
/// banners when they are up, the overall status, queue recovery mode, then process, session,
/// system, egress, authentication, the two auto-retry panels, the retry budgets, post-deploy
/// tasks, cron freshness, log retention, root data, the warm pools, webhook ingest, and the
/// four tables of recent failures, errors and retry events. Its operator actions are the web
/// page's buttons where the page has them, with its confirmations: cleaning up orphans, retrying
/// failures, trashing stale sessions, entering, extending and leaving queue recovery mode,
/// discarding or rescheduling queued jobs, and re-arming the post-deploy tasks. Each answer stays
/// under its button, and the report is read again so the counts move.
struct HealthView: View {
    @EnvironmentObject private var app: AppModel
    @State private var report: HealthReport?
    @State private var error: ZimmerError?
    /// What each action answered, under its button, until that action runs again.
    @State private var receipts: [String: Receipt] = [:]
    @State private var busy: Set<String> = []
    /// The action waiting on its confirmation.
    @State private var confirming: Confirmable?
    /// The queued-job row whose reschedule delay is being asked for.
    @State private var rescheduling: QueuedJobPreview?
    @State private var rescheduleDelay = "0"
    @State private var recoveryReason = ""
    @State private var recoveryMinutes = HealthReport.QueueRecovery.defaultTTLMinutes
    @State private var extendMinutes = HealthReport.QueueRecovery.defaultTTLMinutes

    /// An action's answer, in the tone it deserves: the server's sentence, a cooldown, or a failure.
    private struct Receipt: Equatable {
        enum Tone { case done, wait, failed }
        var text: String
        var tone: Tone
    }

    /// The actions the web page puts behind a confirmation, with its words.
    private enum Confirmable: Identifiable {
        case cleanup(Int), retry(Int), archive, halt([String]), discard(QueuedJobPreview)

        var id: String { key }

        var key: String {
            switch self {
            case .cleanup: return "cleanupProcesses"
            case .retry: return "retrySessions"
            case .archive: return "archiveOld"
            case .halt: return "enterQueueRecovery"
            case let .discard(preview): return "discard.\(preview.scope.jobClass ?? preview.scope.queueName ?? "")"
            }
        }

        /// The web button's `data-confirm`.
        var question: String {
            switch self {
            case let .cleanup(count): return "Are you sure you want to terminate \(count) orphaned process(es)?"
            case let .retry(count): return "Are you sure you want to retry \(count) failed session(s)?"
            case .archive: return "Are you sure you want to move all sessions older than 7 days to trash?"
            case let .halt(queues):
                return "Halt \(queues.joined(separator: ", ")) for the whole instance? Agent sessions keep running; everything else stops until you resume or the timer expires."
            case let .discard(preview): return "Discard \(preview.matched) queued \(preview.label)? This is NOT recoverable — those jobs will never run."
            }
        }

        var button: String {
            switch self {
            case .cleanup: return "Clean Up Orphaned Processes"
            case .retry: return "Retry Failed Sessions"
            case .archive: return "Trash Sessions Older Than 7 Days"
            case .halt: return "Halt Job Processing"
            case .discard: return "Discard"
            }
        }

        var destructive: Bool {
            switch self {
            case .cleanup, .discard, .archive: return true
            case .retry, .halt: return false
            }
        }
    }

    /// The sections drawn by name below; any other `*_health` key is listed generically.
    private static let drawn: Set<String> = [
        "process_health", "session_health", "system_health", "egress_health", "auth_health", "sigterm_retry_health",
        "api_error_retry_health", "retry_budget_health", "post_deploy_task_health", "cron_health", "log_retention_health",
        "root_data_health", "warm_clone_pool_health", "warm_process_pool_health", "inbound_event_health",
    ]

    var body: some View {
        List {
            if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            if let report {
                if !report.banners.isEmpty {
                    Section {
                        SystemBannerRows(banners: report.banners)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                overall(report)
                if let recovery = report.queueRecovery { queueRecovery(recovery) }
                if let system = report.system { queuedJobMaintenance(system) }
                if let process = report.process { self.process(process, status: report.section("process_health")) }
                if let sessions = report.session { self.sessions(sessions, status: report.section("session_health")) }
                if let system = report.system { self.system(system, status: report.section("system_health")) }
                if let egress = report.egress { self.egress(egress, status: report.section("egress_health")) }
                if let auth = report.auth { self.auth(auth, status: report.section("auth_health")) }
                if let retry = report.sigtermRetry { self.retry(retry, title: "SIGTERM Auto-Retry", identifier: "health.sigtermRetry", quota: false) }
                if let retry = report.apiErrorRetry { self.retry(retry, title: "API Error Auto-Retry", identifier: "health.apiErrorRetry", quota: true) }
                maintenanceActions
                if !report.retryBudgets.isEmpty { retryBudgets(report.retryBudgets) }
                if let tasks = report.postDeployTasks { postDeployTasks(tasks, status: report.section("post_deploy_task_health")) }
                if let cron = report.cron { self.cron(cron, status: report.section("cron_health")) }
                if let retention = report.logRetention { logRetention(retention, status: report.section("log_retention_health")) }
                if let rootData = report.rootData { self.rootData(rootData, status: report.section("root_data_health")) }
                if let pool = report.warmClonePool { warmClonePool(pool, status: report.section("warm_clone_pool_health")) }
                if let pool = report.warmProcessPool { warmProcessPool(pool, status: report.section("warm_process_pool_health")) }
                if let inbound = report.inboundEvents { inboundEvents(inbound, status: report.section("inbound_event_health")) }
                let other = report.sections.filter { !Self.drawn.contains($0.key) }
                if !other.isEmpty {
                    Section {
                        ForEach(other) { section in statusRow(section, title: section.title) }
                    } header: {
                        Text("Other sections").themeLabel()
                    }
                    .themeRows()
                }
                if let failures = report.session?.recentFailures, !failures.isEmpty {
                    sessionTable(failures, title: "Recent Failures (24h)", identifier: "health.recentFailures", detail: { failure in
                        [failure.failureReason.map { $0.replacingOccurrences(of: "_", with: " ") }, failure.lastError].compactMap { $0 }.joined(separator: " · ")
                    })
                }
                if let errors = report.system?.recentErrors, !errors.isEmpty { recentErrors(errors) }
                if let events = report.sigtermRetry?.recentSessions, !events.isEmpty {
                    sessionTable(events, title: "Recent SIGTERM Events (24h)", identifier: "health.sigtermEvents", detail: retryDetail)
                }
                if let events = report.apiErrorRetry?.recentSessions, !events.isEmpty {
                    sessionTable(events, title: "Recent API Error Events (24h)", identifier: "health.apiErrorEvents", detail: retryDetail)
                }
            }
        }
        .themeGround()
        .overlay { if report == nil && error == nil { LoadingState() } }
        .task { await load() }
        .refreshable { await load() }
        .navigationTitle("Health")
        .confirmationDialog(
            confirming?.question ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { action in
            Button(action.button, role: action.destructive ? ButtonRole.destructive : nil) { Task { await perform(action) } }
                .accessibilityIdentifier("health.action.\(action.key).confirm")
        }
        .alert(
            "Reschedule \(rescheduling?.label ?? "")",
            isPresented: Binding(get: { rescheduling != nil }, set: { if !$0 { rescheduling = nil } }),
            presenting: rescheduling
        ) { preview in
            TextField("Delay (min)", text: $rescheduleDelay)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("health.reschedule.delay")
            Button("Reschedule") { Task { await reschedule(preview) } }
                .accessibilityIdentifier("health.action.reschedule.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { preview in
            Text("Move \(preview.matched) queued job\(preview.matched == 1 ? "" : "s") to run this many minutes from now; 0 is as soon as the queue allows. The work still happens, later.")
        }
    }

    // MARK: - Actions

    /// Run one action: its receipt stays under its button, in the server's words, and the
    /// report is read again so the counts it changed move. A cooldown is a wait, not a failure.
    private func run(_ key: String, clearing: [String] = [], _ action: @escaping (ZimmerAPI) async throws -> String) async {
        guard busy.insert(key).inserted else { return }
        defer { busy.remove(key) }
        for other in clearing { receipts[other] = nil }
        do {
            let answer = try await action(app.api)
            receipts[key] = Receipt(text: answer, tone: .done)
            Haptics.success()
            await load()
        } catch {
            let failure = error as? ZimmerError ?? .transport(error)
            receipts[key] = Receipt(text: failure.userMessage, tone: failure.isCooldown ? .wait : .failed)
            Haptics.failure()
            app.noteError(failure)
        }
    }

    private func perform(_ action: Confirmable) async {
        switch action {
        case .cleanup: await run(action.key) { try await $0.cleanupProcesses().summary }
        case .retry: await run(action.key) { try await $0.retryFailedSessions().summary }
        case .archive: await run(action.key) { try await $0.archiveOldSessions(days: 7).summary }
        case .halt:
            let reason = recoveryReason
            let minutes = recoveryMinutes
            await run(action.key, clearing: Self.recoveryKeys) { try await $0.enterQueueRecoveryMode(reason: reason, ttlMinutes: minutes).summary }
        case let .discard(preview):
            await run(action.key, clearing: ["queued.\(preview.scope.jobClass ?? "")"]) {
                try await $0.discardQueuedJobs(preview.scope, expectedCount: preview.matched, reason: "discarded from the Health screen in the iOS app").summary
            }
        }
    }

    /// The count the write will check is the one the confirmation shows: previewed first, as
    /// the web row carries the count rendered beside it.
    private func preview(_ jobClass: String, then next: @escaping (QueuedJobPreview) -> Void) async {
        let key = "queued.\(jobClass)"
        do {
            let preview = try await app.api.queuedJobs(QueuedJobScope(jobClass: jobClass))
            if preview.overCap {
                receipts[key] = Receipt(text: "\(preview.matched) queued jobs is over the \(preview.maxPerCall ?? 2_000)-per-call cap; the server would refuse to act on them in one call.", tone: .wait)
                return
            }
            receipts[key] = nil
            next(preview)
        } catch {
            let failure = error as? ZimmerError ?? .transport(error)
            receipts[key] = Receipt(text: failure.userMessage, tone: .failed)
        }
    }

    private func reschedule(_ preview: QueuedJobPreview) async {
        let delay = min(max(Int(rescheduleDelay) ?? 0, 0), maxRescheduleDelayMinutes)
        await run("reschedule.\(preview.scope.jobClass ?? "")", clearing: ["queued.\(preview.scope.jobClass ?? "")"]) {
            try await $0.rescheduleQueuedJobs(preview.scope, expectedCount: preview.matched, delayMinutes: delay).summary
        }
    }

    /// The web page's full-width button, with the action's answer under it.
    /// The queue recovery mode's three keys answer in one slot, so a halt's receipt survives the
    /// report reading the mode as on, and a resume's the mode as off.
    private static let recoveryKeys = ["enterQueueRecovery", "extendQueueRecovery", "exitQueueRecovery"]

    private func actionButton(_ title: String, key: String, tone: Color, showsReceipt: Bool = true, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                HStack(spacing: 8) {
                    if busy.contains(key) { ProgressView().tint(.white).controlSize(.small) }
                    Text(title).font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .foregroundStyle(.white)
                .background(tone, in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
            }
            .buttonStyle(.borderless)
            .disabled(busy.contains(key))
            .accessibilityIdentifier("health.action.\(key)")
            if showsReceipt { receipt(key) }
        }
    }

    @ViewBuilder
    private func receipt(_ key: String) -> some View {
        if let receipt = receipts[key] {
            Text(receipt.text)
                .font(.caption)
                .foregroundStyle(receipt.tone == .done ? Theme.success : receipt.tone == .wait ? Theme.warning : Theme.danger)
                .accessibilityIdentifier("health.action.\(key).result")
        }
    }

    // MARK: - Sections

    private func overall(_ report: HealthReport) -> some View {
        Section {
            statusRow(report.overall, title: "Overall").accessibilityIdentifier("health.overall")
        } footer: {
            if let at = report.generatedAt {
                // The report is stamped as it is read, so "just now" is the usual case.
                let age = Format.age(at)
                Text(verbatim: age == "now" ? "Checked just now" : "Checked \(age) ago").font(.caption).foregroundStyle(Theme.inkMute)
            }
        }
        .themeRows()
    }

    private func queueRecovery(_ recovery: HealthReport.QueueRecovery) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(recovery.active ? "ON — queues halted" : "Off")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(recovery.active ? Theme.warning : Theme.inkSoft)
                    Spacer()
                }
                note("Halts background job execution on \(recovery.haltedQueues.joined(separator: ", ")) so a runaway backlog can be investigated. The \(recovery.liveQueues.joined(separator: ", ")) queue keeps running, so sessions can still be started and can still run. Jobs are frozen, not discarded.")
                let stray = recovery.strayPausedQueues
                if !stray.isEmpty {
                    Text("Paused outside this control: \(stray.joined(separator: ", ")). Either paused by hand, or a resume that failed to lift \(stray.count == 1 ? "it" : "them"). Jobs on \(stray.count == 1 ? "it" : "them") are not running.")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }
                if recovery.active {
                    pairs([
                        ("Halted since", recovery.enteredAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"),
                        ("Auto-resumes", recovery.expiresAt.map { "\($0.formatted(date: .omitted, time: .shortened)) (in \(Format.duration(recovery.expiresInSeconds ?? $0.timeIntervalSinceNow)))" } ?? "—"),
                        ("Entered by", recovery.enteredBy ?? "—"),
                    ])
                    if let reason = recovery.reason, !reason.isEmpty {
                        Text("Reason: \(reason)").font(.caption).foregroundStyle(Theme.ink)
                    }
                    note("While halted, act on the cause: disable a stampeding trigger on the Triggers tab, discard or reschedule queued jobs by class below, or trash runaway sessions with the maintenance actions.")
                    actionButton("Resume Job Processing", key: "exitQueueRecovery", tone: Theme.success, showsReceipt: false) {
                        Task { await run("exitQueueRecovery", clearing: Self.recoveryKeys) { try await $0.exitQueueRecoveryMode().summary } }
                    }
                    Stepper(value: $extendMinutes, in: HealthReport.QueueRecovery.ttlMinutes, step: 5) {
                        Text(verbatim: "Extend by \(extendMinutes) min").font(.caption).foregroundStyle(Theme.inkSoft)
                    }
                    .accessibilityIdentifier("health.recovery.extendMinutes")
                    actionButton("Extend", key: "extendQueueRecovery", tone: Theme.inkSoft, showsReceipt: false) {
                        let minutes = extendMinutes
                        let reason = recovery.reason
                        Task { await run("extendQueueRecovery", clearing: Self.recoveryKeys) { try await $0.enterQueueRecoveryMode(reason: reason, ttlMinutes: minutes).summary } }
                    }
                } else {
                    TextField("Reason (shown in the banner and the Slack alert)", text: $recoveryReason, prompt: Text("e.g. trigger stampede, 900 jobs/hour"))
                        .font(.caption)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("health.recovery.reason")
                    Stepper(value: $recoveryMinutes, in: HealthReport.QueueRecovery.ttlMinutes, step: 5) {
                        Text(verbatim: "Auto-resume after \(recoveryMinutes) min").font(.caption).foregroundStyle(Theme.inkSoft)
                    }
                    .accessibilityIdentifier("health.recovery.minutes")
                    actionButton("Halt Job Processing", key: "enterQueueRecovery", tone: Theme.warning, showsReceipt: false) { confirming = .halt(recovery.haltedQueues) }
                }
                // Whichever of the three last answered, whichever way the mode now reads.
                ForEach(Self.recoveryKeys, id: \.self) { key in receipt(key) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("health.queueRecovery")
        } header: {
            Text("Queue Recovery Mode").themeLabel()
        }
        .themeRows()
    }

    /// The web page's third lever for a runaway queue: the jobs already enqueued, by class, each
    /// with the reversible move and the unrecoverable one. The count a write checks is read just
    /// before the question, so the action is refused rather than taken on a set you did not see.
    private func queuedJobMaintenance(_ system: HealthReport.System) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                note("Jobs that are enqueued but not started, by class. Discarding is not recoverable — the work never runs. Rescheduling is the reversible sibling: the work still happens, later. Running executions, finished history and the agents queue are never eligible.")
                if system.readyByJobClass.isEmpty {
                    Text("Nothing is waiting. Every eligible queue is empty.").font(.subheadline).foregroundStyle(Theme.inkSoft)
                }
                ForEach(system.readyByJobClass) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.name).font(Theme.mono).foregroundStyle(Theme.ink)
                        Text(verbatim: "\(row.count) ready").font(.caption.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                        HStack(spacing: 8) {
                            Button("Reschedule") {
                                rescheduleDelay = "0"
                                Task { await preview(row.name) { rescheduling = $0 } }
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.accent)
                            .accessibilityIdentifier("health.action.reschedule.\(row.name)")
                            Button("Discard", role: .destructive) {
                                Task { await preview(row.name) { confirming = .discard($0) } }
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.danger)
                            .accessibilityIdentifier("health.action.discard.\(row.name)")
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .padding(.vertical, 2)
                }
                // Below the list, not in a row: a discard empties its row, and a reschedule moves
                // the jobs out of the ready breakdown, so the row an answer is about is the one
                // the re-read drops.
                ForEach(receipts.keys.filter { key in ["queued.", "reschedule.", "discard."].contains { key.hasPrefix($0) } }.sorted(), id: \.self) { key in
                    receipt(key)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("health.queuedJobs")
        } header: {
            Text("Queued Job Maintenance").themeLabel()
        } footer: {
            note("Each control carries the count read just before the question. If the queue moves between that read and the tap, the action is refused rather than acting on a set you did not see — try again.")
        }
        .themeRows()
    }

    /// The web page's Maintenance Actions card: the stale-session sweep. Its two dashboard links
    /// are web pages.
    private var maintenanceActions: some View {
        Section {
            actionButton("Trash Sessions Older Than 7 Days", key: "archiveOld", tone: Theme.inkSoft) { confirming = .archive }
                .padding(.vertical, 2)
        } header: {
            Text("Maintenance Actions").themeLabel()
        }
        .themeRows()
    }

    private func process(_ process: HealthReport.Process, status: HealthReport.Section?) -> some View {
        section("Process Health", status: status, identifier: "health.process") {
            tiles([("Recorded", "\(process.recorded)"), ("Active", "\(process.active)"), ("Tracked", "\(process.tracked)"), ("Orphaned", "\(process.orphaned)")],
                  tones: [nil, nil, nil, process.orphaned > 0 ? Theme.danger : nil])
            if !process.observable {
                // Counted in the web container; agent processes belong to the worker's.
                callout("Not visible from here", "\(process.recorded) session\(process.recorded == 1 ? "" : "s") recorded an agent process, and none is visible from the process serving this page. Agent processes are spawned by the worker container, so Active, Tracked and Orphaned all read zero — that is not knowable from here, not none exist.")
            }
            if !process.orphans.isEmpty {
                subhead("Orphaned Processes")
                ForEach(process.orphans) { orphan in
                    HStack(alignment: .top, spacing: 6) {
                        Text(verbatim: "PID \(orphan.pid)").font(Theme.mono).foregroundStyle(Theme.ink)
                        Text(orphan.command.count > 50 ? String(orphan.command.prefix(49)) + "…" : orphan.command).font(Theme.mono).foregroundStyle(Theme.inkSoft)
                    }
                }
            }
            if process.orphaned > 0 {
                actionButton("Clean Up Orphaned Processes", key: "cleanupProcesses", tone: Theme.danger) { confirming = .cleanup(process.orphaned) }
            } else {
                receipt("cleanupProcesses")
            }
        }
    }

    private func sessions(_ sessions: HealthReport.Sessions, status: HealthReport.Section?) -> some View {
        section("Session Health", status: status, identifier: "health.session") {
            tiles([("Total Sessions", "\(sessions.total)"), ("Failure Rate", String(format: "%.1f%%", sessions.failureRate * 100))],
                  tones: [nil, sessions.failureRate > 0.1 ? Theme.warning : nil])
            subhead("Status Distribution")
            counts(sessions.byStatus)
            if !sessions.errorCategories.isEmpty {
                subhead("Error Categories (24h)")
                counts(sessions.errorCategories)
            }
            if !sessions.failureReasons.isEmpty {
                subhead("Failure Reasons (24h)")
                counts(sessions.failureReasons.map { HealthReport.Count($0.name.replacingOccurrences(of: "_", with: " ").capitalizedFirst, $0.count) })
            }
            if !sessions.recentFailures.isEmpty {
                actionButton("Retry Failed Sessions", key: "retrySessions", tone: Theme.warning) { confirming = .retry(sessions.recentFailures.count) }
            } else {
                receipt("retrySessions")
            }
        }
    }

    private func system(_ system: HealthReport.System, status: HealthReport.Section?) -> some View {
        section("System Health", status: status, identifier: "health.system") {
            if let status, status.status != "healthy", let message = status.message {
                // The gate's own sentence: which shape fired.
                Text(message).font(.caption).foregroundStyle(Theme.warning)
            }
            tiles([("Queue Depth", "\(system.queueDepth)"), ("Jobs/Hour", system.jobsPerHour.map(String.init) ?? "—"),
                   ("Last Finished", system.secondsSinceLastFinished.map { "\(Format.duration($0)) ago" } ?? "never")])
            subhead("Queue Statistics")
            tiles([("Ready", "\(system.ready)"), ("Scheduled", "\(system.scheduled)"), ("Processing", "\(system.processing)"), ("Failed", "\(system.failed)")],
                  tones: [nil, nil, nil, system.failed > 0 ? Theme.danger : nil])
            if !system.readyByQueue.isEmpty || !system.inFlightByQueue.isEmpty {
                subhead("Backlog Breakdown")
                if !system.readyByQueue.isEmpty {
                    line("Ready by queue", breakdown(system.readyByQueue))
                    line("Ready by job class", breakdown(system.readyByJobClass))
                    line("Oldest ready by queue", ages(system.oldestReadyByQueue))
                    if let head = system.headOfLine {
                        line("Head of line", "\(head.queue) / \(head.jobClass), waiting \(Format.duration(head.ageSeconds))")
                    }
                }
                if !system.inFlightByQueue.isEmpty {
                    line("In flight by queue", breakdown(system.inFlightByQueue))
                    line("In flight by job class", breakdown(system.inFlightByJobClass))
                    line("Oldest execution by queue", ages(system.oldestExecutionByQueue))
                    line("Youngest execution by queue", ages(system.youngestExecutionByQueue))
                }
            }
            subhead("Workers")
            Text(verbatim: "\(system.activeWorkers) active / \(system.totalWorkers) total workers").font(.subheadline).foregroundStyle(Theme.ink)
            if let database = system.database {
                subhead("Database")
                if database.connected {
                    Text(verbatim: "Connected (Pool: \(database.connectionsInUse ?? 0)/\(database.poolSize ?? 0) in use)").font(.subheadline).foregroundStyle(Theme.success)
                } else {
                    Text(verbatim: "Disconnected: \(database.error ?? "")").font(.subheadline).foregroundStyle(Theme.danger)
                }
            }
        }
    }

    private func egress(_ egress: HealthReport.Egress, status: HealthReport.Section?) -> some View {
        section("Network Egress (DNS)", status: status, identifier: "health.egress") {
            if let message = status?.message { Text(message).font(.caption).foregroundStyle(egress.degraded ? Theme.danger : Theme.inkSoft) }
            pairs([
                ("Primary resolver", egress.resolver ?? "—"),
                ("Last checked", egress.checkedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "not yet probed"),
            ] + (egress.degradedSince.map { [("Degraded since", $0.formatted(date: .abbreviated, time: .shortened))] } ?? []))
        }
    }

    private func auth(_ auth: HealthReport.Auth, status: HealthReport.Section?) -> some View {
        section("Agent Authentication", status: status, identifier: "health.auth") {
            if let message = status?.message { Text(message).font(.caption).foregroundStyle(Theme.inkSoft) }
            let available = auth.availableAccounts.map(String.init) ?? "—"
            let serviceable = (auth.serviceableAccounts ?? 0) > (auth.availableAccounts ?? 0)
                ? " (\(auth.serviceableAccounts ?? 0) serviceable on their own readings — the reset checker restores the difference)" : ""
            pairs([
                ("Session credentials (database)", [auth.credentialsState, auth.credentialsDetail].compactMap { $0 }.joined(separator: " — ")),
                ("Current account", auth.currentAccount ?? "—"),
                ("Accounts available", available + serviceable),
                ("Awaiting re-authentication", auth.needsReauthAccounts.map(String.init) ?? "—"),
                ("Credentials Anthropic refuses", auth.refusedCredentialAccounts.map(String.init) ?? "—"),
            ])
        }
    }

    private func retry(_ retry: HealthReport.Retry, title: String, identifier: String, quota: Bool) -> some View {
        let pressure: HealthReport.Section = quota && (retry.recentQuotaLimits ?? 0) > 0 && !retry.rateLimitPressure
            ? .init(key: identifier, status: "warning", message: "Quota Limit Hit")
            : .init(key: identifier, status: retry.rateLimitPressure ? "warning" : "healthy", message: retry.rateLimitPressure ? "Under Pressure" : "Normal")
        return section(title, status: pressure, badge: pressure.message, identifier: identifier) {
            if quota {
                note("Handles API server errors (500, 529) and transient rate limits (429) with adaptive backoff. Account quota limits are detected and skipped.")
            }
            tiles([("Recovered", "\(retry.recovered)"), ("Exhausted", "\(retry.exhausted)")] + (quota ? [("Quota Limits", "\(retry.quotaLimitSessions ?? 0)")] : []),
                  tones: [Theme.success, retry.exhausted > 0 ? Theme.danger : nil, (retry.quotaLimitSessions ?? 0) > 0 ? Theme.warning : nil])
            subhead("Retry Statistics")
            tiles([("Total Sessions", "\(retry.totalSessions)"), ("Total Retries", "\(retry.totalRetries)"), (quota ? "Errors 24h" : "Last 24h", "\(retry.recent24h)")]
                  + (quota ? [("Quota Limits 24h", "\(retry.recentQuotaLimits ?? 0)")] : []))
            if quota, let recent = retry.recentQuotaLimits, recent > 0 {
                callout(nil, "\(recent) session(s) hit an account quota limit in the last 24 hours. These are daily/weekly limits that require hours to reset.")
            }
            subhead("Rate Limit Status")
            Text(verbatim: "\(retry.rateLimitEvents5m ?? 0) events in last 5 min · Delay mode: \(retry.delayMode) · Max retries: \(retry.maxRetries.map(String.init) ?? "—")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.ink)
            if retry.delayMode == "escalated" {
                callout(nil, "System is experiencing rate limit pressure. \(quota ? "API error retry delays" : "Retry delays") are escalated (60s, 180s, 300s) to allow recovery.")
            }
        }
    }

    private func retryBudgets(_ budgets: [HealthReport.RetryBudget]) -> some View {
        Section {
            ForEach(budgets) { budget in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(budget.label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(verbatim: "max \(budget.maxRetries.map(String.init) ?? "—") · \(budget.countKey ?? budget.name)").font(Theme.mono).foregroundStyle(Theme.inkMute)
                    }
                    tiles([("Sessions", "\(budget.sessions)"), ("Attempts", "\(budget.attempts)"), ("Recent (24h)", "\(budget.recent)"), ("Exhausted", "\(budget.exhausted)")],
                          tones: [nil, nil, budget.recent > 0 ? Theme.warning : nil, budget.exhausted > 0 ? Theme.danger : nil])
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Retry Budgets").themeLabel()
        } footer: {
            note("Every bounded auto-recovery loop — how much of each budget the fleet has spent, and how many sessions ran out of it.")
        }
        .themeRows()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("health.retryBudgets")
    }

    private func postDeployTasks(_ tasks: HealthReport.PostDeployTasks, status: HealthReport.Section?) -> some View {
        section("Post-Deploy Tasks", status: status, identifier: "health.postDeployTasks") {
            note("One-time steps in db/post_deploy/, run automatically after a deploy.")
            tiles([("Succeeded", "\(tasks.succeeded)"), ("Pending", "\(tasks.pending + tasks.awaitingFirstTick)"), ("Running", "\(tasks.running)"), ("Failed", "\(tasks.failed)")],
                  tones: [Theme.success, nil, nil, tasks.failed > 0 ? Theme.danger : nil])
            if tasks.tasks.isEmpty {
                Text(tasks.awaitingFirstTick > 0 ? "\(tasks.awaitingFirstTick) task(s) written, none run yet." : "No post-deploy tasks have been written.")
                    .font(.subheadline).foregroundStyle(Theme.inkSoft)
            }
            ForEach(tasks.tasks) { task in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(task.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                        Spacer()
                        capsule(task.blocked ? "blocked" : task.status, tone: taskTone(task))
                    }
                    HStack(spacing: 6) {
                        Text(task.version).font(Theme.mono)
                        if !task.registered { Text("task file removed").foregroundStyle(Theme.warning) }
                        if task.attempts > 1 { Text(verbatim: "\(task.attempts) attempts") }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.inkMute)
                    HStack(spacing: 6) {
                        Text(verbatim: "Last run " + (task.lastRanAt.map { Format.age($0) == "now" ? "just now" : "\(Format.age($0)) ago" } ?? "never"))
                        if let next = task.nextAttemptAt {
                            Text(verbatim: next > Date() ? "· retry in \(Format.duration(next.timeIntervalSinceNow))" : "· retry due")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkSoft)
                    Text(verbatim: task.stats.isEmpty ? "—" : task.stats.map { "\($0.name)=\($0.count)" }.joined(separator: " "))
                        .font(Theme.mono)
                        .foregroundStyle(Theme.inkSoft)
                    if let lastError = task.lastError, task.status != "succeeded" {
                        Text(lastError).font(Theme.mono).foregroundStyle(Theme.danger).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }
            if tasks.failed > 0 || tasks.awaitingFirstTick > 0 {
                actionButton("Re-arm and run now", key: "runPostDeployTasks", tone: tasks.blocked > 0 ? Theme.danger : Theme.accentFill) {
                    Task { await run("runPostDeployTasks") { try await $0.runPostDeployTasks().summary } }
                }
            } else {
                receipt("runPostDeployTasks")
            }
        }
    }

    private func taskTone(_ task: HealthReport.PostDeployTasks.Task) -> Color {
        if task.blocked { return Theme.danger }
        switch task.status {
        case "succeeded": return Theme.success
        case "failed": return Theme.danger
        case "running": return Theme.accent
        default: return Theme.inkMute
        }
    }

    private func cron(_ cron: HealthReport.Cron, status: HealthReport.Section?) -> some View {
        section("Cron Freshness", status: status, identifier: "health.cron") {
            note("Whether each job in config/cron_schedule.rb is still being enqueued, judged against its own cadence — and whether it stopped at any point in the last \(cron.historyWindowSeconds.map(Format.duration) ?? "day").")
            tiles([("On schedule", "\(cron.fresh)"), ("Stale", "\(cron.stale)"), ("Behind", "\(cron.overdue)"), ("Not judged", "\(cron.disabled + cron.exempt)")],
                  tones: [Theme.success, cron.stale > 0 ? Theme.danger : nil, cron.overdue > 0 ? Theme.warning : nil, nil])
            if let message = status?.message { Text(message).font(.caption).foregroundStyle(Theme.inkSoft) }
            ForEach(cron.recovered) { key in
                Text(verbatim: "\(key.key) is enqueuing now, but was silent \(key.longestGapSeconds.map(Format.duration) ?? "a while") until \(key.gapEndedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "recently").")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            if let since = cron.cronRunningSince {
                note("Newest cron-running worker started \(Format.age(since)) ago. A tick counts against a key only if other keys' rows show the cron manager fired it.")
            }
            ForEach(cron.behind) { key in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(key.key).font(Theme.mono).foregroundStyle(Theme.ink)
                        Spacer()
                        capsule(key.state, tone: cronTone(key.state))
                    }
                    Text(verbatim: "\(key.jobClass ?? "") · \(key.cron ?? "")").font(.caption).foregroundStyle(Theme.inkMute)
                    if let reason = key.reason { Text(reason).font(.caption).foregroundStyle(Theme.inkSoft) }
                }
                .padding(.vertical, 2)
            }
            if !cron.keys.isEmpty {
                DisclosureGroup {
                    ForEach(cron.keys) { key in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(key.key).font(Theme.mono).foregroundStyle(Theme.ink)
                                Spacer()
                                capsule(key.state, tone: cronTone(key.state))
                            }
                            HStack(spacing: 6) {
                                Text(key.cron ?? "")
                                Text("·")
                                Text(verbatim: key.lastEnqueuedAt.map { "\(Format.age($0)) ago" } ?? "never")
                                Text("·")
                                Text(verbatim: "\(key.ticksInWindow) tick\(key.ticksInWindow == 1 ? "" : "s")")
                                if key.stoppedInWindow { Text("stopped").foregroundStyle(Theme.warning) }
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.inkMute)
                        }
                        .padding(.vertical, 2)
                    }
                } label: {
                    Text(verbatim: "Every key (\(cron.keys.count))").font(.subheadline).foregroundStyle(Theme.accent)
                }
                .tint(Theme.accent)
                .accessibilityIdentifier("health.cron.keys")
            }
        }
    }

    private func cronTone(_ state: String) -> Color {
        switch state {
        case "fresh": return Theme.success
        case "overdue": return Theme.warning
        case "stale": return Theme.danger
        default: return Theme.inkMute
        }
    }

    private func logRetention(_ retention: HealthReport.LogRetention, status: HealthReport.Section?) -> some View {
        section("Log Retention", status: status, identifier: "health.logRetention") {
            note("logs rows are kept \(retention.retentionDays ?? 0) days (\(retention.verboseRetentionDays ?? 0) for verbose), pruned by LogRetentionJob.")
            tiles([("Rows (est.)", retention.estimatedRows.map(Format.compact) ?? "—"), ("Total size", Format.bytes(retention.totalBytes)),
                   ("Indexes", Format.bytes(retention.indexBytes)), ("Oldest row", retention.oldestLogAt.map { "\(Format.age($0)) ago" } ?? "—"),
                   ("Oldest verbose", retention.oldestVerboseLogAt.map { "\(Format.age($0)) ago" } ?? "—")])
            if let message = status?.message { Text(message).font(.caption).foregroundStyle(Theme.inkSoft) }
        }
    }

    private func rootData(_ rootData: HealthReport.RootData, status: HealthReport.Section?) -> some View {
        section("Root Data", status: status, identifier: "health.rootData") {
            note("Each agent root's persistent records, written through the root_data MCP tools. Expired records are pruned hourly by RootDataRetentionJob.")
            tiles([("Records", rootData.totalRecords.formatted()), ("Data", Format.bytes(rootData.totalDataBytes)), ("Overdue expiry", rootData.overdueExpiredRecords.formatted())],
                  tones: [nil, nil, rootData.overdueExpiredRecords > 0 ? Theme.warning : nil])
            if let message = status?.message { Text(message).font(.caption).foregroundStyle(Theme.inkSoft) }
            ForEach(rootData.namespaces) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.namespace).font(Theme.mono).foregroundStyle(Theme.ink)
                    Text(verbatim: "\(row.collections) collections · \(row.records.formatted()) records · \(Format.bytes(row.dataBytes)) · last write \(row.lastWrittenAt.map { "\(Format.age($0)) ago" } ?? "never")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.inkSoft)
                }
                .padding(.vertical, 2)
            }
            ForEach(rootData.nearCap) { row in
                Text(verbatim: "\(row.namespace)/\(row.collection): \(row.records.formatted()) of \((rootData.maxRecordsPerCollection ?? 0).formatted()) records")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    private func warmClonePool(_ pool: HealthReport.WarmClonePool, status: HealthReport.Section?) -> some View {
        section("Warm Clone Pool", status: status, identifier: "health.warmClonePool") {
            note("Ready-made git clones a starting session claims instead of cloning. Scope \(pool.scope ?? "unknown").")
            tiles([("Router claimed", "\(pool.routerClaimed)"), ("Router missed", "\(pool.routerMissed)"), ("Other roots claimed", "\(pool.otherClaimed)"), ("Other roots missed", "\(pool.otherMissed)")],
                  tones: [nil, pool.routerMissed > 0 ? Theme.warning : nil, nil, pool.otherMissed > 0 ? Theme.warning : nil])
            note([status?.message, "Counts are session starts in the last \(pool.outcomeWindowHours ?? 0) hours.",
                  pool.lastPass.map { "Last refill \(Format.age($0.at)) ago: \($0.built) built, \($0.recycled) recycled." }].compactMap { $0 }.joined(separator: " "))
            ForEach(pool.targets) { target in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(verbatim: "\(target.repo)@\(target.branch)").font(Theme.mono).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(verbatim: "\(target.ready) / \(target.size) ready").font(.caption.monospacedDigit()).foregroundStyle(target.ready < target.size ? Theme.warning : Theme.success)
                    }
                    Text(verbatim: "newest \(target.newestAgeSeconds.map { "\(Format.duration($0)) old" } ?? "—") · \(target.starts.formatted()) starts (\(pool.windowDays ?? 0)d) · \(target.roots.prefix(5).joined(separator: ", "))\(target.roots.count > 5 ? " +\(target.roots.count - 5)" : "")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.inkSoft)
                    if let error = target.error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
                }
                .padding(.vertical, 2)
            }
            if !pool.passedOver.isEmpty {
                DisclosureGroup {
                    ForEach(pool.passedOver) { candidate in
                        Text(verbatim: "\(candidate.repo)@\(candidate.branch): \(candidate.starts) starts — \(candidate.reason ?? "")")
                            .font(.caption)
                            .foregroundStyle(Theme.inkSoft)
                    }
                } label: {
                    Text(verbatim: "Ranked and not pooled (\(pool.passedOver.count))").font(.subheadline).foregroundStyle(Theme.accent)
                }
                .tint(Theme.accent)
            }
        }
    }

    private func warmProcessPool(_ pool: HealthReport.WarmProcessPool, status: HealthReport.Section?) -> some View {
        section("Warm Router Process", status: status, identifier: "health.warmProcessPool") {
            note("An idle Claude Code process a Quick Router request takes instead of spawning one. It makes no API call while it waits.")
            let cold = pool.coldStarts.reduce(0) { $0 + $1.count }
            tiles([("Claimed", "\(pool.claimed)"), ("Missed", "\(pool.missed)"), ("Started cold", "\(cold)")],
                  tones: [nil, pool.missed > 0 ? Theme.warning : nil, nil])
            note([status?.message, "Counts are router session starts in the last \(pool.outcomeWindowHours ?? 0) hours; a process is replaced after \(pool.maxAgeMinutes ?? 0) minutes.",
                  pool.lastPass.map { "Last refill \(Format.age($0.at)) ago: \($0.built) built, \($0.recycled) recycled." }].compactMap { $0 }.joined(separator: " "))
            if cold > 0 {
                Text(verbatim: "Why the others started cold: " + pool.coldStarts.map { "\($0.name) \($0.count)" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
            ForEach(pool.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.id).font(Theme.mono).foregroundStyle(Theme.ink)
                        if let pid = entry.pid { Text(verbatim: "pid \(pid)").font(Theme.mono).foregroundStyle(Theme.inkMute) }
                        Spacer()
                        capsule(entry.state ?? "unknown", tone: entry.state == "ready" ? Theme.success : Theme.inkMute)
                    }
                    Text(verbatim: [entry.ageSeconds.map(Format.duration), entry.model, entry.account].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.inkSoft)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func inboundEvents(_ inbound: HealthReport.InboundEvents, status: HealthReport.Section?) -> some View {
        section("Webhook Ingest", status: status, identifier: "health.inboundEvents") {
            note("Deliveries per source, and trigger events by the path that claimed them, over the last \(Int((inbound.windowSeconds ?? 0) / 3600)) hours.")
            ForEach(inbound.sources) { source in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(source.label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        if let mode = source.mode { capsule(mode, tone: Theme.inkMute) }
                    }
                    tiles([("Last delivery", source.lastDeliveryAt.map { "\(Format.duration(-$0.timeIntervalSinceNow)) ago" } ?? "—"),
                           ("Deliveries", "\(source.deliveries)"), ("Claimed via webhook", "\(source.webhookClaims)"), ("Claimed via poll", "\(source.pollClaims)")],
                          tones: [nil, nil, nil, source.mode == "webhook" && source.pollClaims > 0 ? Theme.warning : nil])
                }
                .padding(.vertical, 2)
            }
            if let message = status?.message { Text(message).font(.caption).foregroundStyle(Theme.inkSoft) }
        }
    }

    private func sessionTable(_ rows: [HealthReport.SessionSummary], title: String, identifier: String,
                              detail: @escaping (HealthReport.SessionSummary) -> String) -> some View {
        Section {
            ForEach(rows) { row in
                Button {
                    app.path = [row.id]
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title ?? "Session \(row.id)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                        HStack(spacing: 5) {
                            Text(verbatim: "#\(row.id)").font(Theme.mono)
                            if let status = row.status {
                                Text("·")
                                Text(status.replacingOccurrences(of: "_", with: " "))
                            }
                            if let root = row.gitRoot {
                                Text("·")
                                Text(root).font(Theme.mono)
                            }
                            if let at = row.at {
                                Text("·")
                                Text(verbatim: "\(Format.age(at)) ago")
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.inkMute)
                        let text = detail(row)
                        if !text.isEmpty { Text(text).font(.caption).foregroundStyle(Theme.danger).lineLimit(3) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(identifier).\(row.id)")
            }
        } header: {
            Text(title).themeLabel()
        }
        .themeRows()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func retryDetail(_ row: HealthReport.SessionSummary) -> String {
        row.retryCount.map { "\($0) retr\($0 == 1 ? "y" : "ies")" } ?? ""
    }

    private func recentErrors(_ errors: [HealthReport.System.RecentError]) -> some View {
        Section {
            ForEach(errors) { error in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if let at = error.createdAt { Text(verbatim: "\(Format.age(at)) ago") }
                        Text("·")
                        Text(error.source == "job" ? "job" : "session log")
                        if let session = error.sessionID {
                            Text("·")
                            Button { app.path = [session] } label: { Text(verbatim: "#\(session)").font(Theme.mono).foregroundStyle(Theme.accent) }
                                .buttonStyle(.plain)
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkMute)
                    Text(error.content).font(Theme.mono).foregroundStyle(Theme.ink).textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Recent Errors (1h)").themeLabel()
        } footer: {
            note("Errors recorded in a session's log or by a background job. An error that only reached stdout is in neither; nothing here means none was recorded, not that nothing is wrong.")
        }
        .themeRows()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("health.recentErrors")
    }

    // MARK: - Pieces

    /// A section as the web page's card: its heading with the status beside it, then its body.
    private func section<Body: View>(_ title: String, status: HealthReport.Section?, badge: String? = nil, identifier: String,
                                     @ViewBuilder body: () -> Body) -> some View {
        section(title, status: status, badge: badge, identifier: identifier, body: body, footer: { EmptyView() })
    }

    private func section<Body: View, Footer: View>(_ title: String, status: HealthReport.Section?, badge: String? = nil, identifier: String,
                                                   @ViewBuilder body: () -> Body, @ViewBuilder footer: () -> Footer) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) { body() }
                .padding(.vertical, 2)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
        } header: {
            HStack {
                Text(title).themeLabel()
                Spacer()
                if let status { capsule(badge ?? status.status.capitalized, tone: Self.color(status.status)) }
            }
        } footer: {
            footer()
        }
        .themeRows()
    }

    private func statusRow(_ section: HealthReport.Section, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.ink)
                Spacer()
                capsule(section.status.capitalized, tone: Self.color(section.status))
            }
            if let message = section.message {
                Text(message).font(.caption).foregroundStyle(Theme.inkSoft).lineLimit(3)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func capsule(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(tone)
            .background(tone.opacity(0.14), in: Capsule())
    }

    /// The web page's dl grid of figures: a label over a number, two to a row.
    private func tiles(_ items: [(String, String)], tones: [Color?] = []) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.0).font(.caption2).foregroundStyle(Theme.inkMute)
                    Text(item.1)
                        .font(.system(.title3, weight: .semibold).monospacedDigit())
                        .foregroundStyle(tones.indices.contains(index) ? (tones[index] ?? Theme.ink) : Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }

    private func pairs(_ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in line(item.0, item.1) }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(Theme.inkMute)
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(Theme.ink)
        }
    }

    private func subhead(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(Theme.inkSoft).padding(.top, 2)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.inkMute)
    }

    private func callout(_ title: String?, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title { Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.warning) }
            Text(text).font(.caption).foregroundStyle(Theme.inkSoft)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
    }

    /// The web page's "name: n" chips.
    private func counts(_ counts: [HealthReport.Count]) -> some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(counts) { count in
                Text(verbatim: "\(count.name): \(count.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .foregroundStyle(Theme.inkSoft)
                    .background(Theme.well, in: Capsule())
            }
        }
    }

    private func breakdown(_ counts: [HealthReport.Count]) -> String {
        counts.isEmpty ? "—" : counts.map { "\($0.name) \($0.count)" }.joined(separator: ", ")
    }

    private func ages(_ ages: [HealthReport.Age]) -> String {
        ages.isEmpty ? "—" : ages.map { "\($0.name) \(Format.duration($0.seconds))" }.joined(separator: ", ")
    }

    /// The web UI's health colours.
    static func color(_ status: String) -> Color {
        switch status {
        case "healthy": return Theme.success
        case "warning": return Theme.warning
        case "critical": return Theme.danger
        default: return Theme.inkMute
        }
    }

    private func load() async {
        do {
            let loaded = try await app.api.health()
            report = loaded
            error = nil
            app.note(loaded)
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
