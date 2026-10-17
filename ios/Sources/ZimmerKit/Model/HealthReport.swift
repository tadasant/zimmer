import Foundation

/// The web UI's Health page (`GET /api/v1/health`): the overall status, then every section
/// of `_health_content.html.erb` with the counts, tables and lists it prints, in its order.
/// Each section is optional: a report missing one shows the rest.
public struct HealthReport: Hashable, Sendable {
    public struct Section: Hashable, Sendable, Identifiable {
        public var key: String
        public var status: String
        public var message: String?
        public var id: String { key }

        public init(key: String, status: String, message: String? = nil) {
            self.key = key
            self.status = status
            self.message = message
        }

        /// `process_health` → "Process".
        public var title: String {
            key.replacingOccurrences(of: "_health", with: "").replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// `QueueRecoveryMode.status`: whether the demand-side queues are halted, and until when.
    public struct QueueRecovery: Hashable, Sendable {
        public var active: Bool
        public var enteredAt: Date?
        public var expiresAt: Date?
        public var expiresInSeconds: Double?
        public var reason: String?
        public var enteredBy: String?
        public var haltedQueues: [String]
        /// What GoodJob actually has paused, which may include a queue paused by hand.
        public var pausedQueues: [String]
        public var liveQueues: [String]

        public init(active: Bool, enteredAt: Date? = nil, expiresAt: Date? = nil, expiresInSeconds: Double? = nil, reason: String? = nil,
                    enteredBy: String? = nil, haltedQueues: [String] = [], pausedQueues: [String] = [], liveQueues: [String] = []) {
            self.active = active
            self.enteredAt = enteredAt
            self.expiresAt = expiresAt
            self.expiresInSeconds = expiresInSeconds
            self.reason = reason
            self.enteredBy = enteredBy
            self.haltedQueues = haltedQueues
            self.pausedQueues = pausedQueues
            self.liveQueues = liveQueues
        }

        /// Queues paused outside this control: by hand in /jobs, or a resume that failed.
        public var strayPausedQueues: [String] {
            pausedQueues.filter { !(active && haltedQueues.contains($0)) }
        }
    }

    public struct Process: Hashable, Sendable {
        public struct Orphan: Hashable, Sendable, Identifiable {
            public var pid: Int
            public var command: String
            public var id: Int { pid }
        }

        public var recorded: Int
        public var active: Int
        public var tracked: Int
        public var orphaned: Int
        /// Whether the counts are evidence: agent processes belong to the worker container,
        /// so the web container reads zero and says so.
        public var observable: Bool
        public var orphans: [Orphan]
    }

    public struct SessionSummary: Hashable, Sendable, Identifiable {
        public var id: Int
        public var title: String?
        public var status: String?
        public var gitRoot: String?
        public var failureReason: String?
        public var lastError: String?
        public var retryCount: Int?
        public var at: Date?
    }

    public struct Sessions: Hashable, Sendable {
        public var total: Int
        public var failureRate: Double
        public var byStatus: [Count]
        public var errorCategories: [Count]
        public var failureReasons: [Count]
        public var averageDurationSeconds: Double?
        /// Recent Failures (24h).
        public var recentFailures: [SessionSummary]
    }

    /// One "name: count" of a breakdown line.
    public struct Count: Hashable, Sendable, Identifiable {
        public var name: String
        public var count: Int
        public var id: String { name }

        public init(_ name: String, _ count: Int) {
            self.name = name
            self.count = count
        }
    }

    public struct Age: Hashable, Sendable, Identifiable {
        public var name: String
        public var seconds: Double
        public var id: String { name }
    }

    public struct System: Hashable, Sendable {
        public struct HeadOfLine: Hashable, Sendable {
            public var queue: String
            public var jobClass: String
            public var ageSeconds: Double
        }

        public struct Database: Hashable, Sendable {
            public var connected: Bool
            public var connectionsInUse: Int?
            public var poolSize: Int?
            public var error: String?
        }

        public struct RecentError: Hashable, Sendable, Identifiable {
            public var id: String
            public var source: String
            public var sessionID: Int?
            public var content: String
            public var createdAt: Date?
        }

        public var queueDepth: Int
        public var jobsPerHour: Int?
        public var secondsSinceLastFinished: Double?
        public var ready: Int
        public var scheduled: Int
        public var processing: Int
        public var failed: Int
        public var readyByQueue: [Count]
        public var readyByJobClass: [Count]
        public var oldestReadyByQueue: [Age]
        public var headOfLine: HeadOfLine?
        public var inFlightByQueue: [Count]
        public var inFlightByJobClass: [Count]
        public var oldestExecutionByQueue: [Age]
        public var youngestExecutionByQueue: [Age]
        public var activeWorkers: Int
        public var totalWorkers: Int
        public var database: Database?
        /// Recent Errors (1h), newest first.
        public var recentErrors: [RecentError]
    }

    public struct Egress: Hashable, Sendable {
        public var degraded: Bool
        public var resolver: String?
        public var detail: String?
        public var degradedSince: Date?
        public var checkedAt: Date?
    }

    public struct Auth: Hashable, Sendable {
        public var credentialsState: String?
        public var credentialsDetail: String?
        public var currentAccount: String?
        public var availableAccounts: Int?
        public var serviceableAccounts: Int?
        public var needsReauthAccounts: Int?
        public var refusedCredentialAccounts: Int?
    }

    /// SIGTERM Auto-Retry and API Error Auto-Retry, which share a shape; the quota counts
    /// are the API error section's own.
    public struct Retry: Hashable, Sendable {
        public var totalSessions: Int
        public var totalRetries: Int
        public var recovered: Int
        public var exhausted: Int
        public var recent24h: Int
        public var rateLimitPressure: Bool
        public var rateLimitEvents5m: Int?
        public var delayMode: String
        public var maxRetries: Int?
        public var quotaLimitSessions: Int?
        public var recentQuotaLimits: Int?
        public var recentSessions: [SessionSummary]
    }

    public struct RetryBudget: Hashable, Sendable, Identifiable {
        public var name: String
        public var label: String
        public var countKey: String?
        public var maxRetries: Int?
        public var sessions: Int
        public var attempts: Int
        public var recent: Int
        public var exhausted: Int
        public var id: String { name }
    }

    public struct PostDeployTasks: Hashable, Sendable {
        public struct Task: Hashable, Sendable, Identifiable {
            public var version: String
            public var name: String
            public var status: String
            public var registered: Bool
            public var attempts: Int
            public var blocked: Bool
            public var stats: [Count]
            public var lastRanAt: Date?
            public var nextAttemptAt: Date?
            public var lastError: String?
            public var id: String { version }
        }

        public var succeeded: Int
        public var pending: Int
        public var running: Int
        public var failed: Int
        public var blocked: Int
        public var awaitingFirstTick: Int
        public var tasks: [Task]
    }

    public struct Cron: Hashable, Sendable {
        public struct Key: Hashable, Sendable, Identifiable {
            public var key: String
            public var jobClass: String?
            public var cron: String?
            /// `fresh`, `overdue`, `stale`, `disabled` or `exempt`.
            public var state: String
            public var reason: String?
            public var lastEnqueuedAt: Date?
            public var ticksInWindow: Int
            public var stoppedInWindow: Bool
            public var longestGapSeconds: Double?
            public var gapEndedAt: Date?
            public var id: String { key }
        }

        public var fresh: Int
        public var stale: Int
        public var overdue: Int
        public var disabled: Int
        public var exempt: Int
        public var cronRunningSince: Date?
        public var historyWindowSeconds: Double?
        public var keys: [Key]

        /// Every key not on schedule, worst first — the list the web page prints above its table.
        public var behind: [Key] { keys.filter { $0.state != "fresh" } }
        /// Keys on schedule that were silent earlier in the window.
        public var recovered: [Key] { keys.filter { $0.state == "fresh" && $0.stoppedInWindow } }
    }

    public struct LogRetention: Hashable, Sendable {
        public var estimatedRows: Int?
        public var totalBytes: Int
        public var indexBytes: Int
        public var oldestLogAt: Date?
        public var oldestVerboseLogAt: Date?
        public var retentionDays: Int?
        public var verboseRetentionDays: Int?
    }

    public struct RootData: Hashable, Sendable {
        public struct Namespace: Hashable, Sendable, Identifiable {
            public var namespace: String
            public var collections: Int
            public var records: Int
            public var dataBytes: Int
            public var lastWrittenAt: Date?
            public var id: String { namespace }
        }

        public struct NearCap: Hashable, Sendable, Identifiable {
            public var namespace: String
            public var collection: String
            public var records: Int
            public var id: String { "\(namespace)/\(collection)" }
        }

        public var totalRecords: Int
        public var totalDataBytes: Int
        public var overdueExpiredRecords: Int
        public var maxRecordsPerCollection: Int?
        public var namespaces: [Namespace]
        public var nearCap: [NearCap]
    }

    public struct Pass: Hashable, Sendable {
        public var at: Date
        public var built: Int
        public var recycled: Int
    }

    public struct WarmClonePool: Hashable, Sendable {
        public struct Target: Hashable, Sendable, Identifiable {
            public var repo: String
            public var branch: String
            public var ready: Int
            public var size: Int
            public var newestAgeSeconds: Double?
            public var starts: Int
            public var roots: [String]
            public var error: String?
            public var id: String { "\(repo)@\(branch)" }
        }

        public struct PassedOver: Hashable, Sendable, Identifiable {
            public var repo: String
            public var branch: String
            public var starts: Int
            public var reason: String?
            public var id: String { "\(repo)@\(branch)" }
        }

        public var enabled: Bool
        public var scope: String?
        public var routerClaimed: Int
        public var routerMissed: Int
        public var otherClaimed: Int
        public var otherMissed: Int
        public var outcomeWindowHours: Int?
        public var windowDays: Int?
        public var lastPass: Pass?
        public var targets: [Target]
        public var passedOver: [PassedOver]
    }

    public struct WarmProcessPool: Hashable, Sendable {
        public struct Entry: Hashable, Sendable, Identifiable {
            public var id: String
            public var pid: Int?
            public var state: String?
            public var ageSeconds: Double?
            public var model: String?
            public var account: String?
        }

        public var enabled: Bool
        public var claimed: Int
        public var missed: Int
        /// Every other outcome, by reason — the router starts that went cold.
        public var coldStarts: [Count]
        public var outcomeWindowHours: Int?
        public var maxAgeMinutes: Int?
        public var lastPass: Pass?
        public var entries: [Entry]
    }

    public struct InboundEvents: Hashable, Sendable {
        public struct Source: Hashable, Sendable, Identifiable {
            public var name: String
            public var mode: String?
            public var lastDeliveryAt: Date?
            public var deliveries: Int
            public var webhookClaims: Int
            public var pollClaims: Int
            public var id: String { name }

            /// `github` → "GitHub", as the web page labels it.
            public var label: String { name == "github" ? "GitHub" : name.capitalized }
        }

        public var windowSeconds: Double?
        public var sources: [Source]
    }

    public var overall: Section
    /// Every `*_health` section's status, in key order.
    public var sections: [Section]
    public var generatedAt: Date?
    public var queueRecovery: QueueRecovery?
    public var process: Process?
    public var session: Sessions?
    public var system: System?
    public var egress: Egress?
    public var auth: Auth?
    public var sigtermRetry: Retry?
    public var apiErrorRetry: Retry?
    public var retryBudgets: [RetryBudget]
    public var postDeployTasks: PostDeployTasks?
    public var cron: Cron?
    public var logRetention: LogRetention?
    public var rootData: RootData?
    public var warmClonePool: WarmClonePool?
    public var warmProcessPool: WarmProcessPool?
    public var inboundEvents: InboundEvents?

    public init(overall: Section, sections: [Section], generatedAt: Date? = nil, queueRecovery: QueueRecovery? = nil,
                process: Process? = nil, session: Sessions? = nil, system: System? = nil, egress: Egress? = nil, auth: Auth? = nil,
                sigtermRetry: Retry? = nil, apiErrorRetry: Retry? = nil, retryBudgets: [RetryBudget] = [],
                postDeployTasks: PostDeployTasks? = nil, cron: Cron? = nil, logRetention: LogRetention? = nil, rootData: RootData? = nil,
                warmClonePool: WarmClonePool? = nil, warmProcessPool: WarmProcessPool? = nil, inboundEvents: InboundEvents? = nil) {
        self.overall = overall
        self.sections = sections
        self.generatedAt = generatedAt
        self.queueRecovery = queueRecovery
        self.process = process
        self.session = session
        self.system = system
        self.egress = egress
        self.auth = auth
        self.sigtermRetry = sigtermRetry
        self.apiErrorRetry = apiErrorRetry
        self.retryBudgets = retryBudgets
        self.postDeployTasks = postDeployTasks
        self.cron = cron
        self.logRetention = logRetention
        self.rootData = rootData
        self.warmClonePool = warmClonePool
        self.warmProcessPool = warmProcessPool
        self.inboundEvents = inboundEvents
    }

    public func section(_ key: String) -> Section? {
        sections.first { $0.key == key }
    }

    /// The two conditions the web layout announces on every page: queue recovery mode on,
    /// and network egress degraded.
    public var banners: SystemBanners {
        SystemBanners(queueRecovery: queueRecovery?.active == true ? queueRecovery : nil,
                      egressDegraded: egress?.degraded == true ? egress : nil)
    }

    /// Read from `GET /api/v1/health`.
    public static func parse(_ data: Data) throws -> HealthReport {
        guard let root = JSONObject(try JSONSerialization.jsonObject(with: data)),
              let report = root.object("health_report")
        else { throw ZimmerError.decoding("health report: no health_report key") }

        let overall = report.status("overall_status").map { Section(key: "overall", status: $0.status, message: $0.message) }
            ?? Section(key: "overall", status: "unknown")
        let sections = report.raw.keys.sorted().compactMap { key -> Section? in
            guard key.hasSuffix("_health"), let section = report.object(key), let status = section.status() else { return nil }
            return Section(key: key, status: status.status, message: status.message)
        }

        return HealthReport(
            overall: overall, sections: sections, generatedAt: report.date("generated_at"),
            queueRecovery: root.object("queue_recovery_mode").map(queueRecovery),
            process: report.object("process_health").map(process),
            session: report.object("session_health").map(sessions),
            system: report.object("system_health").map(system),
            egress: report.object("egress_health").map(egress),
            auth: report.object("auth_health").map(auth),
            sigtermRetry: report.object("sigterm_retry_health").map { retry($0, prefix: "sigterm", at: "last_sigterm_at") },
            apiErrorRetry: report.object("api_error_retry_health").map { retry($0, prefix: "api_error", at: "last_api_error_at") },
            retryBudgets: report.object("retry_budget_health")?.objects("budgets").compactMap(retryBudget) ?? [],
            postDeployTasks: report.object("post_deploy_task_health").map(postDeployTasks),
            cron: report.object("cron_health").map(cron),
            logRetention: report.object("log_retention_health").map(logRetention),
            rootData: report.object("root_data_health").map(rootData),
            warmClonePool: report.object("warm_clone_pool_health").map(warmClonePool),
            warmProcessPool: report.object("warm_process_pool_health").map(warmProcessPool),
            inboundEvents: report.object("inbound_event_health").map(inboundEvents)
        )
    }

    static func queueRecovery(_ json: JSONObject) -> QueueRecovery {
        QueueRecovery(active: json.bool("active") ?? false, enteredAt: json.date("entered_at"), expiresAt: json.date("expires_at"),
                      expiresInSeconds: json.double("expires_in_seconds"), reason: json.string("reason"), enteredBy: json.string("entered_by"),
                      haltedQueues: json.strings("halted_queues"), pausedQueues: json.strings("paused_queues"), liveQueues: json.strings("live_queues"))
    }

    private static func process(_ json: JSONObject) -> Process {
        Process(recorded: json.int("recorded_count") ?? 0, active: json.int("active_count") ?? 0, tracked: json.int("tracked_count") ?? 0,
                orphaned: json.int("orphaned_count") ?? 0, observable: json.bool("observable") ?? true,
                orphans: json.objects("orphaned_processes").compactMap { orphan in
                    guard let pid = orphan.int("pid") else { return nil }
                    return Process.Orphan(pid: pid, command: orphan.string("command") ?? "")
                })
    }

    private static func counts(_ pairs: [(String, Int)]) -> [Count] { pairs.map { Count($0.0, $0.1) } }
    private static func ages(_ pairs: [(String, Double)]) -> [Age] { pairs.map { Age(name: $0.0, seconds: $0.1) } }

    private static func sessionSummary(_ json: JSONObject, at: String) -> SessionSummary? {
        guard let id = json.int("id") else { return nil }
        return SessionSummary(id: id, title: json.string("title"), status: json.string("status"), gitRoot: json.string("git_root"),
                              failureReason: json.string("failure_reason"), lastError: json.string("last_error"),
                              retryCount: json.int("retry_count"), at: json.date(at))
    }

    private static func sessions(_ json: JSONObject) -> Sessions {
        Sessions(total: json.int("total_sessions") ?? 0, failureRate: json.double("failure_rate") ?? 0,
                 byStatus: counts(json.counts("sessions_by_status")), errorCategories: counts(json.counts("error_categories")),
                 failureReasons: counts(json.counts("failure_reasons")), averageDurationSeconds: json.double("average_duration_seconds"),
                 recentFailures: json.objects("recent_failures").compactMap { sessionSummary($0, at: "updated_at") })
    }

    private static func system(_ json: JSONObject) -> System {
        let queue = json.object("queue_stats") ?? JSONObject([:])
        let workers = json.object("worker_stats")
        let head = queue.object("head_of_line").flatMap { head -> System.HeadOfLine? in
            guard let queueName = head.string("queue"), let jobClass = head.string("job_class") else { return nil }
            return System.HeadOfLine(queue: queueName, jobClass: jobClass, ageSeconds: head.double("age_seconds") ?? 0)
        }
        let database = json.object("database_status").map { db in
            System.Database(connected: db.bool("connected") ?? false, connectionsInUse: db.int("connections_in_use"),
                            poolSize: db.int("pool_size"), error: db.string("error"))
        }
        return System(
            queueDepth: json.int("queue_depth") ?? queue.int("ready_count") ?? 0,
            jobsPerHour: queue.int("processing_rate_per_hour"),
            secondsSinceLastFinished: queue.double("seconds_since_last_finished"),
            ready: queue.int("ready_count") ?? 0, scheduled: queue.int("scheduled_count") ?? 0,
            processing: queue.int("claimed_count") ?? 0, failed: queue.int("failed_count") ?? 0,
            readyByQueue: counts(queue.counts("ready_count_by_queue")), readyByJobClass: counts(queue.counts("ready_count_by_job_class")),
            oldestReadyByQueue: ages(queue.ages("oldest_ready_age_seconds_by_queue")), headOfLine: head,
            inFlightByQueue: counts(queue.counts("claimed_count_by_queue")), inFlightByJobClass: counts(queue.counts("claimed_count_by_job_class")),
            oldestExecutionByQueue: ages(queue.ages("oldest_claimed_age_seconds_by_queue")),
            youngestExecutionByQueue: ages(queue.ages("youngest_claimed_age_seconds_by_queue")),
            activeWorkers: workers?.int("active_workers") ?? 0, totalWorkers: workers?.int("total_workers") ?? 0,
            database: database,
            recentErrors: json.objects("recent_errors").compactMap { error in
                guard let content = error.string("content") else { return nil }
                return System.RecentError(id: error.string("id") ?? content, source: error.string("source") ?? "unknown",
                                          sessionID: error.int("session_id"), content: content, createdAt: error.date("created_at"))
            }
        )
    }

    private static func egress(_ json: JSONObject) -> Egress {
        Egress(degraded: json.status()?.status == "critical", resolver: json.string("resolver"), detail: json.string("detail"),
               degradedSince: json.date("degraded_since"), checkedAt: json.date("checked_at"))
    }

    private static func auth(_ json: JSONObject) -> Auth {
        Auth(credentialsState: json.string("credentials_state"), credentialsDetail: json.string("credentials_detail"),
             currentAccount: json.string("credentials_owner"), availableAccounts: json.int("available_accounts"),
             serviceableAccounts: json.int("serviceable_accounts"), needsReauthAccounts: json.int("needs_reauth_accounts"),
             refusedCredentialAccounts: json.int("refused_credential_accounts"))
    }

    private static func retry(_ json: JSONObject, prefix: String, at: String) -> Retry {
        Retry(totalSessions: json.int("total_\(prefix)_sessions") ?? 0, totalRetries: json.int("total_retries_attempted") ?? 0,
              recovered: json.int("successful_recovery_count") ?? 0, exhausted: json.int("exhausted_retry_count") ?? 0,
              recent24h: json.int("recent_\(prefix)_count") ?? 0, rateLimitPressure: json.bool("rate_limit_pressure") ?? false,
              rateLimitEvents5m: json.int("rate_limit_events_5min"), delayMode: json.string("current_delay_mode") ?? "normal",
              maxRetries: json.int("max_retries"), quotaLimitSessions: json.int("quota_limit_sessions_count"),
              recentQuotaLimits: json.int("recent_quota_limit_count"),
              recentSessions: json.objects("recent_\(prefix)_sessions").compactMap { sessionSummary($0, at: at) })
    }

    private static func retryBudget(_ json: JSONObject) -> RetryBudget? {
        guard let name = json.string("name") else { return nil }
        return RetryBudget(name: name, label: json.string("label") ?? name, countKey: json.string("count_key"), maxRetries: json.int("max_retries"),
                           sessions: json.int("total_sessions") ?? 0, attempts: json.int("total_retries_attempted") ?? 0,
                           recent: json.int("recent_count") ?? 0, exhausted: json.int("exhausted_retry_count") ?? 0)
    }

    private static func postDeployTasks(_ json: JSONObject) -> PostDeployTasks {
        PostDeployTasks(
            succeeded: json.int("succeeded") ?? 0, pending: json.int("pending") ?? 0, running: json.int("running") ?? 0,
            failed: json.int("failed") ?? 0, blocked: json.int("blocked") ?? 0, awaitingFirstTick: json.int("awaiting_first_tick") ?? 0,
            tasks: json.objects("tasks").compactMap { task in
                guard let version = task.string("version") else { return nil }
                let stats = task.object("stats").map { stats in
                    stats.raw.keys.sorted().compactMap { key -> Count? in
                        guard let value = stats.int(key) else { return nil }
                        return Count(key, value)
                    }
                } ?? []
                return PostDeployTasks.Task(version: version, name: task.string("name") ?? version, status: task.string("status") ?? "unknown",
                                            registered: task.bool("registered") ?? true, attempts: task.int("attempts") ?? 0,
                                            blocked: task.bool("blocked") ?? false, stats: stats, lastRanAt: task.date("last_ran_at"),
                                            nextAttemptAt: task.date("next_attempt_at"), lastError: task.string("last_error"))
            }
        )
    }

    private static func cron(_ json: JSONObject) -> Cron {
        let counts = json.object("counts") ?? JSONObject([:])
        return Cron(
            fresh: counts.int("fresh") ?? 0, stale: counts.int("stale") ?? 0, overdue: counts.int("overdue") ?? 0,
            disabled: counts.int("disabled") ?? 0, exempt: counts.int("exempt") ?? 0,
            cronRunningSince: json.date("cron_running_since"), historyWindowSeconds: json.double("history_window_seconds"),
            keys: json.objects("keys").compactMap { reading in
                guard let key = reading.string("key") else { return nil }
                return Cron.Key(key: key, jobClass: reading.string("job_class"), cron: reading.string("cron"),
                                state: reading.string("state") ?? "unknown", reason: reading.string("reason"),
                                lastEnqueuedAt: reading.date("last_enqueued_at"), ticksInWindow: reading.int("ticks_in_window") ?? 0,
                                stoppedInWindow: reading.bool("stopped_in_window") ?? false,
                                longestGapSeconds: reading.double("longest_gap_seconds"), gapEndedAt: reading.date("gap_ended_at"))
            }
        )
    }

    private static func logRetention(_ json: JSONObject) -> LogRetention {
        LogRetention(estimatedRows: json.int("estimated_rows"), totalBytes: json.int("total_bytes") ?? 0, indexBytes: json.int("index_bytes") ?? 0,
                     oldestLogAt: json.date("oldest_log_at"), oldestVerboseLogAt: json.date("oldest_verbose_log_at"),
                     retentionDays: json.int("retention_days"), verboseRetentionDays: json.int("verbose_retention_days"))
    }

    private static func rootData(_ json: JSONObject) -> RootData {
        RootData(
            totalRecords: json.int("total_records") ?? 0, totalDataBytes: json.int("total_data_bytes") ?? 0,
            overdueExpiredRecords: json.int("overdue_expired_records") ?? 0, maxRecordsPerCollection: json.int("max_records_per_collection"),
            namespaces: json.objects("namespaces").compactMap { row in
                guard let namespace = row.string("namespace") else { return nil }
                return RootData.Namespace(namespace: namespace, collections: row.int("collections") ?? 0, records: row.int("records") ?? 0,
                                          dataBytes: row.int("data_bytes") ?? 0, lastWrittenAt: row.date("last_written_at"))
            },
            nearCap: json.objects("near_cap").compactMap { row in
                guard let namespace = row.string("namespace"), let collection = row.string("collection") else { return nil }
                return RootData.NearCap(namespace: namespace, collection: collection, records: row.int("records") ?? 0)
            }
        )
    }

    private static func pass(_ json: JSONObject?) -> Pass? {
        guard let json, let at = json.date("at") else { return nil }
        return Pass(at: at, built: json.int("built") ?? 0, recycled: json.int("recycled") ?? 0)
    }

    /// `repo_url` as the web page prints it: the repository's name, without `.git`.
    static func repoName(_ url: String?) -> String {
        guard let url else { return "" }
        var name = url.split(separator: "/").last.map(String.init) ?? url
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name
    }

    private static func warmClonePool(_ json: JSONObject) -> WarmClonePool {
        let outcomes = json.object("outcomes")
        let router = outcomes?.object("router")
        let other = outcomes?.object("other")
        return WarmClonePool(
            enabled: json.bool("enabled") ?? false, scope: json.string("scope"),
            routerClaimed: router?.int("claimed") ?? 0, routerMissed: router?.int("missed") ?? 0,
            otherClaimed: other?.int("claimed") ?? 0, otherMissed: other?.int("missed") ?? 0,
            outcomeWindowHours: json.int("outcome_window_hours"), windowDays: json.int("window_days"), lastPass: pass(json.object("last_pass")),
            targets: json.objects("targets").map { target in
                WarmClonePool.Target(repo: repoName(target.string("repo_url")), branch: target.string("branch") ?? "", ready: target.int("ready") ?? 0,
                                     size: target.int("size") ?? 0, newestAgeSeconds: target.double("newest_age_seconds"), starts: target.int("starts") ?? 0,
                                     roots: target.counts("roots").map(\.0), error: target.string("error"))
            },
            passedOver: json.objects("passed_over").map { candidate in
                WarmClonePool.PassedOver(repo: repoName(candidate.string("repo_url")), branch: candidate.string("branch") ?? "",
                                         starts: candidate.int("starts") ?? 0, reason: candidate.string("reason"))
            }
        )
    }

    private static func warmProcessPool(_ json: JSONObject) -> WarmProcessPool {
        let outcomes = json.object("outcomes")
        let others = outcomes.map { all in
            all.raw.keys.sorted().compactMap { key -> Count? in
                guard key != "claimed", key != "missed", let count = all.int(key) else { return nil }
                return Count(key, count)
            }.sorted { $0.count > $1.count }
        } ?? []
        return WarmProcessPool(
            enabled: json.bool("enabled") ?? false, claimed: outcomes?.int("claimed") ?? 0, missed: outcomes?.int("missed") ?? 0,
            coldStarts: others, outcomeWindowHours: json.int("outcome_window_hours"), maxAgeMinutes: json.int("max_age_minutes"),
            lastPass: pass(json.object("last_pass")),
            entries: json.objects("entries").map { entry in
                WarmProcessPool.Entry(id: entry.string("id") ?? "", pid: entry.int("pid"), state: entry.string("state"),
                                      ageSeconds: entry.double("age_seconds"), model: entry.string("model"), account: entry.string("account"))
            }
        )
    }

    private static func inboundEvents(_ json: JSONObject) -> InboundEvents {
        InboundEvents(windowSeconds: json.double("window_seconds"), sources: json.objects("sources").compactMap { source in
            guard let name = source.string("name") else { return nil }
            return InboundEvents.Source(name: name, mode: source.string("mode"), lastDeliveryAt: source.date("last_delivery_at"),
                                        deliveries: source.int("deliveries_in_window") ?? 0, webhookClaims: source.int("webhook_claims_in_window") ?? 0,
                                        pollClaims: source.int("poll_claims_in_window") ?? 0)
        })
    }
}

/// What the web layout says on every page, when it has to: the two site-wide alerts,
/// nil each when quiet.
public struct SystemBanners: Hashable, Sendable {
    public var queueRecovery: HealthReport.QueueRecovery?
    public var egressDegraded: HealthReport.Egress?

    public init(queueRecovery: HealthReport.QueueRecovery? = nil, egressDegraded: HealthReport.Egress? = nil) {
        self.queueRecovery = queueRecovery
        self.egressDegraded = egressDegraded
    }

    public var isEmpty: Bool { queueRecovery == nil && egressDegraded == nil }
}
