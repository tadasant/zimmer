import Foundation

// MARK: - The Health page's operator actions

/// `POST /api/v1/health/cleanup_processes`: which orphaned agent processes were ended.
public struct ProcessCleanup: Hashable, Sendable {
    public struct Failure: Hashable, Sendable {
        public var pid: Int
        public var reason: String?
    }

    public var terminated: [Int]
    public var alreadyDead: [Int]
    public var failed: [Failure]

    public init(terminated: [Int] = [], alreadyDead: [Int] = [], failed: [Failure] = []) {
        self.terminated = terminated
        self.alreadyDead = alreadyDead
        self.failed = failed
    }

    /// One line for the page: what the web flash says after the same button.
    public var summary: String {
        var parts = ["Terminated \(Self.count(terminated.count, "process"))"]
        if !alreadyDead.isEmpty { parts.append("\(alreadyDead.count) already gone") }
        if !failed.isEmpty { parts.append("\(failed.count) could not be ended") }
        return parts.joined(separator: "; ") + "."
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : noun.hasSuffix("s") ? "es" : "s")"
    }

    static func parse(_ json: JSONObject) -> ProcessCleanup {
        ProcessCleanup(
            terminated: json.ints("terminated"), alreadyDead: json.ints("already_dead"),
            failed: json.objects("failed").compactMap { failure in
                failure.int("pid").map { Failure(pid: $0, reason: failure.string("reason")) }
            }
        )
    }
}

/// `POST /api/v1/health/retry_sessions`: which failed sessions were restarted, and which the
/// server declined to, with its reason for each.
public struct SessionRetry: Hashable, Sendable {
    public struct Skipped: Hashable, Sendable, Identifiable {
        public var sessionID: Int
        public var reason: String?
        public var id: Int { sessionID }
    }

    public var retried: [Int]
    public var skipped: [Skipped]
    public var failed: [Skipped]

    public init(retried: [Int] = [], skipped: [Skipped] = [], failed: [Skipped] = []) {
        self.retried = retried
        self.skipped = skipped
        self.failed = failed
    }

    public var summary: String {
        var parts = ["Retried \(ProcessCleanup.count(retried.count, "session"))"]
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        if !failed.isEmpty { parts.append("\(failed.count) failed to start") }
        return parts.joined(separator: "; ") + "."
    }

    static func parse(_ json: JSONObject) -> SessionRetry {
        func rows(_ key: String) -> [Skipped] {
            json.objects(key).compactMap { row in row.int("session_id").map { Skipped(sessionID: $0, reason: row.string("reason")) } }
        }
        return SessionRetry(retried: json.ints("retried"), skipped: rows("skipped"), failed: rows("failed"))
    }
}

/// `POST /api/v1/health/archive_old`: which sessions were moved to the trash.
public struct SessionArchive: Hashable, Sendable {
    public var archived: [Int]
    public var failed: [SessionRetry.Skipped]

    public init(archived: [Int] = [], failed: [SessionRetry.Skipped] = []) {
        self.archived = archived
        self.failed = failed
    }

    public var summary: String {
        var parts = ["Trashed \(ProcessCleanup.count(archived.count, "session"))"]
        if !failed.isEmpty { parts.append("\(failed.count) could not be trashed") }
        return parts.joined(separator: "; ") + "."
    }

    static func parse(_ json: JSONObject) -> SessionArchive {
        SessionArchive(archived: json.ints("archived"), failed: json.objects("failed").compactMap { row in
            row.int("session_id").map { SessionRetry.Skipped(sessionID: $0, reason: row.string("reason")) }
        })
    }
}

/// `POST /api/v1/health/run_post_deploy_tasks`: how many failed tasks were re-armed, with the
/// summary counts the pass starts from.
public struct PostDeployRearm: Hashable, Sendable {
    public var rearmed: Int
    public var enqueued: Bool
    public var pending: Int
    public var failed: Int

    public init(rearmed: Int, enqueued: Bool, pending: Int = 0, failed: Int = 0) {
        self.rearmed = rearmed
        self.enqueued = enqueued
        self.pending = pending
        self.failed = failed
    }

    public var summary: String {
        let armed = rearmed == 0 ? "Nothing to re-arm" : "Re-armed \(ProcessCleanup.count(rearmed, "failed task"))"
        return armed + (enqueued ? "; a pass is queued." : ".")
    }

    static func parse(_ json: JSONObject) -> PostDeployRearm {
        PostDeployRearm(rearmed: json.int("rearmed") ?? 0, enqueued: json.bool("enqueued") ?? false,
                        pending: json.int("pending") ?? 0, failed: json.int("failed") ?? 0)
    }
}

/// What a queued-job maintenance call acts on: a job class, a queue, or both. The server
/// refuses an empty scope.
public struct QueuedJobScope: Hashable, Sendable {
    public var jobClass: String?
    public var queueName: String?

    public init(jobClass: String? = nil, queueName: String? = nil) {
        self.jobClass = jobClass
        self.queueName = queueName
    }

    /// The web panel's label for a row: "SlackTriggerPollerJob on pollers".
    public var label: String {
        [jobClass, queueName.map { "on \($0)" }].compactMap { $0 }.joined(separator: " ")
    }

    var json: [String: Any] {
        var body: [String: Any] = [:]
        if let jobClass { body["job_class"] = jobClass }
        if let queueName { body["queue_name"] = queueName }
        return body
    }

    static func parse(_ json: JSONObject?) -> QueuedJobScope {
        QueuedJobScope(jobClass: json?.string("job_class"), queueName: json?.string("queue_name"))
    }
}

/// `GET /api/v1/health/queued_jobs`: how many rows a maintenance call on this scope would
/// touch, by class and queue — the `expected_count` the write demands.
public struct QueuedJobPreview: Hashable, Sendable {
    public var scope: QueuedJobScope
    public var matched: Int
    public var byJobClass: [HealthReport.Count]
    public var byQueue: [HealthReport.Count]
    public var overCap: Bool
    public var maxPerCall: Int?

    public init(scope: QueuedJobScope, matched: Int, byJobClass: [HealthReport.Count] = [], byQueue: [HealthReport.Count] = [],
                overCap: Bool = false, maxPerCall: Int? = nil) {
        self.scope = scope
        self.matched = matched
        self.byJobClass = byJobClass
        self.byQueue = byQueue
        self.overCap = overCap
        self.maxPerCall = maxPerCall
    }

    /// The row as the web panel labels it: the class on its queue(s).
    public var label: String {
        let queues = byQueue.map(\.name)
        guard let jobClass = scope.jobClass ?? byJobClass.first?.name else { return scope.label }
        return queues.isEmpty ? jobClass : "\(jobClass) on \(queues.joined(separator: ", "))"
    }

    static func parse(_ json: JSONObject) -> QueuedJobPreview {
        QueuedJobPreview(scope: QueuedJobScope.parse(json.object("scope")), matched: json.int("matched") ?? 0,
                         byJobClass: json.counts("by_job_class").map { HealthReport.Count($0.0, $0.1) },
                         byQueue: json.counts("by_queue").map { HealthReport.Count($0.0, $0.1) },
                         overCap: json.bool("over_cap") ?? false, maxPerCall: json.int("max_per_call"))
    }
}

/// What a discard or reschedule did (`QueuedJobMaintenance::Result#as_json`).
public struct QueuedJobReceipt: Hashable, Sendable {
    /// `discard` or `reschedule`.
    public var action: String
    public var scope: QueuedJobScope
    public var matched: Int
    public var affected: Int
    public var byJobClass: [HealthReport.Count]
    public var byQueue: [HealthReport.Count]
    public var skippedTotal: Int
    public var scheduledAt: Date?

    public init(action: String, scope: QueuedJobScope, matched: Int, affected: Int, byJobClass: [HealthReport.Count] = [],
                byQueue: [HealthReport.Count] = [], skippedTotal: Int = 0, scheduledAt: Date? = nil) {
        self.action = action
        self.scope = scope
        self.matched = matched
        self.affected = affected
        self.byJobClass = byJobClass
        self.byQueue = byQueue
        self.skippedTotal = skippedTotal
        self.scheduledAt = scheduledAt
    }

    public var summary: String {
        let verb = action == "discard" ? "Discarded" : "Rescheduled"
        var text = "\(verb) \(ProcessCleanup.count(affected, "queued job")) (\(scope.label))"
        if let scheduledAt, action != "discard" { text += " to run at \(scheduledAt.formatted(date: .omitted, time: .shortened))" }
        if skippedTotal > 0 { text += "; \(skippedTotal) skipped" }
        return text + "."
    }

    static func parse(_ json: JSONObject) -> QueuedJobReceipt {
        QueuedJobReceipt(action: json.string("action") ?? "", scope: QueuedJobScope.parse(json.object("scope")),
                         matched: json.int("matched") ?? 0, affected: json.int("affected") ?? 0,
                         byJobClass: json.counts("by_job_class").map { HealthReport.Count($0.0, $0.1) },
                         byQueue: json.counts("by_queue").map { HealthReport.Count($0.0, $0.1) },
                         skippedTotal: json.int("skipped_total") ?? 0, scheduledAt: json.date("scheduled_at"))
    }
}

extension HealthReport.QueueRecovery {
    /// The sentence the page shows after entering, extending or resuming.
    public var summary: String {
        guard active else { return "Job processing resumed." }
        let until = expiresAt.map { " until \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        return "Queue recovery mode is on\(until)."
    }

    /// `ttl_minutes` is clamped to this range by the server (`QueueRecoveryMode::MIN_TTL..MAX_TTL`).
    public static let ttlMinutes = 5...240
    public static let defaultTTLMinutes = 60
}

/// `ttl_minutes` as the server will take it.
public func clampedRecoveryTTL(_ minutes: Int) -> Int {
    min(max(minutes, HealthReport.QueueRecovery.ttlMinutes.lowerBound), HealthReport.QueueRecovery.ttlMinutes.upperBound)
}

/// `delay_minutes` on a reschedule is clamped to a week by the server (`MAX_RESCHEDULE_DELAY`).
public let maxRescheduleDelayMinutes = 7 * 24 * 60

extension ZimmerError {
    /// The server's cooldown on cleanup, retries and trashing: one of those every thirty
    /// seconds per caller (`HealthActionCooldown`). Shown in place rather than as a failure.
    public var isCooldown: Bool {
        if case let .http(status, _) = self { return status == 429 }
        return false
    }
}

// MARK: - Costs

/// `POST /api/v1/costs/backfill`: the sweep queued, or the one already in flight, with the
/// ledger's coverage as the page's banner shows it.
public struct BackfillRequest: Hashable, Sendable {
    public var queued: Bool
    /// `queued`, `running` or `complete`: the run's own state.
    public var runStatus: String?
    public var coverage: CostSnapshot.Coverage?

    public init(queued: Bool, runStatus: String? = nil, coverage: CostSnapshot.Coverage? = nil) {
        self.queued = queued
        self.runStatus = runStatus
        self.coverage = coverage
    }

    static func parse(_ data: Data) throws -> BackfillRequest {
        guard let root = JSONObject(try JSONSerialization.jsonObject(with: data)) else { throw ZimmerError.decoding("backfill: not an object") }
        return BackfillRequest(queued: root.bool("queued") ?? false, runStatus: root.object("run")?.string("status"),
                               coverage: root.object("ledger_coverage").map(CostSnapshot.coverage))
    }
}

// MARK: - The CLIs page

/// `GET /api/v1/clis/status`: each command-line tool's installation and authentication, as
/// the worker last checked it, with the instructions the page prints for one that is not ready.
public struct CliStatusReport: Hashable, Sendable {
    public struct Tool: Hashable, Sendable, Identifiable {
        public var key: String
        public var name: String
        /// Nil while the first check has not run.
        public var installed: Bool?
        public var authenticated: Bool?
        public var version: String?
        /// One line of operator-facing state beyond installed and authenticated (Pi's extensions).
        public var details: String?
        public var installInstructions: String?
        public var authInstructions: String?
        /// `oauth` or `env_var`.
        public var authMethod: String?
        public var envVarName: String?
        public var id: String { key }

        public init(key: String, name: String, installed: Bool?, authenticated: Bool?, version: String? = nil, details: String? = nil,
                    installInstructions: String? = nil, authInstructions: String? = nil, authMethod: String? = nil, envVarName: String? = nil) {
            self.key = key
            self.name = name
            self.installed = installed
            self.authenticated = authenticated
            self.version = version
            self.details = details
            self.installInstructions = installInstructions
            self.authInstructions = authInstructions
            self.authMethod = authMethod
            self.envVarName = envVarName
        }

        public var isReady: Bool { installed == true && authenticated == true }
        public var usesEnvVar: Bool { authMethod == "env_var" }

        /// The page's badge for installation: a check not yet run reads as such, not as absent.
        public var installedLabel: String {
            switch installed {
            case .some(true): return "Installed"
            case .some(false): return "Not Installed"
            case .none: return "Checking…"
            }
        }

        public var authenticatedLabel: String {
            switch authenticated {
            case .some(true): return "Authenticated"
            case .some(false): return "Not Authenticated"
            case .none: return "Checking…"
            }
        }

        /// The line to copy for an environment-variable tool that is not set, as the page prints it.
        public var envVarHint: String? {
            envVarName.map { "\($0)=your_token_here" }
        }
    }

    public var tools: [Tool]
    /// Nil while loading.
    public var allAuthenticated: Bool?
    public var unauthenticatedCount: Int
    public var generatedAt: Date?
    /// The cache was empty: the worker's check has not run since the deploy.
    public var loading: Bool

    public init(tools: [Tool], allAuthenticated: Bool?, unauthenticatedCount: Int, generatedAt: Date? = nil, loading: Bool = false) {
        self.tools = tools
        self.allAuthenticated = allAuthenticated
        self.unauthenticatedCount = unauthenticatedCount
        self.generatedAt = generatedAt
        self.loading = loading
    }

    /// The banner over the list, in the web page's words.
    public var headline: String {
        if loading { return "Checking CLI tools…" }
        if allAuthenticated == true { return "All CLI tools are installed and authenticated" }
        let n = unauthenticatedCount
        return "\(n) CLI tool\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") attention"
    }

    /// The page lists tools in the server's order (`CliStatusService::CLI_TOOLS`); JSON hands
    /// them over unordered, so the known keys lead and anything else follows by name.
    static let knownOrder = ["gh", "claude", "codex", "pi", "fly"]

    static func parse(_ data: Data) throws -> CliStatusReport {
        guard let root = JSONObject(try JSONSerialization.jsonObject(with: data)) else { throw ZimmerError.decoding("cli status: not an object") }
        // `GET …/status` wraps the report in `cli_status`; `POST …/refresh` in `current_status`.
        let report = root.object("cli_status") ?? root.object("current_status") ?? root
        return parse(report, unauthenticatedCount: root.int("unauthenticated_count") ?? report.int("unauthenticated_count") ?? 0)
    }

    static func parse(_ report: JSONObject, unauthenticatedCount: Int) -> CliStatusReport {
        let hash = report.object("tools") ?? JSONObject([:])
        let keys = hash.raw.keys.sorted { a, b in
            let ia = knownOrder.firstIndex(of: a) ?? knownOrder.count
            let ib = knownOrder.firstIndex(of: b) ?? knownOrder.count
            return ia == ib ? a < b : ia < ib
        }
        let tools = keys.compactMap { key -> Tool? in
            guard let tool = hash.object(key) else { return nil }
            return Tool(key: key, name: tool.string("name") ?? key, installed: tool.bool("installed"), authenticated: tool.bool("authenticated"),
                        version: tool.string("version"), details: tool.string("details"),
                        installInstructions: tool.string("install_instructions")?.trimmingCharacters(in: .whitespacesAndNewlines),
                        authInstructions: tool.string("auth_instructions")?.trimmingCharacters(in: .whitespacesAndNewlines),
                        authMethod: tool.string("auth_method"), envVarName: tool.string("env_var_name"))
        }
        return CliStatusReport(tools: tools, allAuthenticated: report.bool("all_authenticated"), unauthenticatedCount: unauthenticatedCount,
                               generatedAt: report.date("generated_at"), loading: report.bool("loading") ?? false)
    }
}

extension JSONObject {
    /// An array of ids.
    func ints(_ key: String) -> [Int] {
        (raw[key] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
    }
}
