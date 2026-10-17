import Foundation

/// The web UI's Costs page (`GET /api/v1/costs`), whole: the ledger's coverage, the window's
/// totals, where the money went by kind of token, by day, by agent root, by context feature,
/// by experimental setting, by model, by thread kind, by runtime and by ad hoc source, the
/// most expensive sessions, and the burn rates the spot gate reads.
public struct CostSnapshot: Hashable, Sendable {
    /// One row of a by-X table: its name, dollars, tokens and calls, and the rows behind it
    /// (a root's estimated context-feature split; a day's biggest roots).
    public struct Row: Hashable, Sendable, Identifiable {
        public var label: String
        public var costUSD: Double
        public var tokens: Int?
        public var apiCalls: Int?
        public var details: [Row]
        public var id: String { label }

        public init(label: String, costUSD: Double, tokens: Int? = nil, apiCalls: Int? = nil, details: [Row] = []) {
            self.label = label
            self.costUSD = costUSD
            self.tokens = tokens
            self.apiCalls = apiCalls
            self.details = details
        }

        /// Dollars per call, as the web row's drilldown prints it.
        public var perCallUSD: Double? {
            guard let apiCalls, apiCalls > 0 else { return nil }
            return costUSD / Double(apiCalls)
        }
    }

    public struct Day: Hashable, Sendable, Identifiable {
        public var day: String
        public var costUSD: Double
        public var sessionCostUSD: Double?
        public var adhocCostUSD: Double?
        public var tokens: Int?
        public var apiCalls: Int?
        public var roots: [Row]
        public var models: [Row]
        public var id: String { day }

        public init(day: String, costUSD: Double, sessionCostUSD: Double? = nil, adhocCostUSD: Double? = nil, tokens: Int? = nil,
                    apiCalls: Int? = nil, roots: [Row] = [], models: [Row] = []) {
            self.day = day
            self.costUSD = costUSD
            self.sessionCostUSD = sessionCostUSD
            self.adhocCostUSD = adhocCostUSD
            self.tokens = tokens
            self.apiCalls = apiCalls
            self.roots = roots
            self.models = models
        }
    }

    public struct TopSession: Hashable, Sendable, Identifiable {
        public var sessionID: Int
        public var costUSD: Double
        public var tokens: Int?
        public var title: String?
        public var apiCalls: Int?
        public var id: Int { sessionID }

        public init(sessionID: Int, costUSD: Double, tokens: Int? = nil, title: String? = nil, apiCalls: Int? = nil) {
            self.sessionID = sessionID
            self.costUSD = costUSD
            self.tokens = tokens
            self.title = title
            self.apiCalls = apiCalls
        }
    }

    /// The headline tiles.
    public struct Totals: Hashable, Sendable {
        public var costUSD: Double
        public var sessionCostUSD: Double
        public var adhocCostUSD: Double
        public var tokens: Int
        public var apiCalls: Int

        public init(costUSD: Double, sessionCostUSD: Double = 0, adhocCostUSD: Double = 0, tokens: Int = 0, apiCalls: Int = 0) {
            self.costUSD = costUSD
            self.sessionCostUSD = sessionCostUSD
            self.adhocCostUSD = adhocCostUSD
            self.tokens = tokens
            self.apiCalls = apiCalls
        }

        /// Zimmer's own calls as a share of the total.
        public var adhocShare: Double { costUSD > 0 ? adhocCostUSD / costUSD : 0 }
    }

    /// "Where the money goes": one kind of token and its share.
    public struct Component: Hashable, Sendable, Identifiable {
        public var component: String
        public var costUSD: Double
        public var share: Double
        public var id: String { component }

        public init(component: String, costUSD: Double, share: Double) {
            self.component = component
            self.costUSD = costUSD
            self.share = share
        }
    }

    /// How much history the ledger holds, and whether the one-time sweep of it has run.
    public struct Coverage: Hashable, Sendable {
        /// `never_run`, `queued`, `running` or `complete`.
        public var status: String
        /// A sweep has finished at least once; a `running` one is then a re-scan.
        public var complete: Bool
        public var progressPct: Int?
        public var directoriesDone: Int?
        public var directoriesTotal: Int?
        public var filesScanned: Int?
        public var finishedAt: Date?
        public var lastRanAt: Date?
        public var lastError: String?
        public var coversSince: Date?
        public var coversUntil: Date?

        public init(status: String, complete: Bool = false, progressPct: Int? = nil, directoriesDone: Int? = nil, directoriesTotal: Int? = nil,
                    filesScanned: Int? = nil, finishedAt: Date? = nil, lastRanAt: Date? = nil, lastError: String? = nil,
                    coversSince: Date? = nil, coversUntil: Date? = nil) {
            self.status = status
            self.complete = complete
            self.progressPct = progressPct
            self.directoriesDone = directoriesDone
            self.directoriesTotal = directoriesTotal
            self.filesScanned = filesScanned
            self.finishedAt = finishedAt
            self.lastRanAt = lastRanAt
            self.lastError = lastError
            self.coversSince = coversSince
            self.coversUntil = coversUntil
        }

        public var swept: Bool { status == "complete" }

        /// The banner's headline, as the web page words it.
        public var headline: String {
            switch status {
            case "complete": return "History backfilled"
            case "running":
                let verb = complete ? "Re-scanning history" : "Backfilling history"
                return progressPct.map { "\(verb) — \($0)%" } ?? verb
            case "queued": return "History sweep queued"
            default: return "History not backfilled yet"
            }
        }
    }

    /// Context features (estimated): where the bytes in each prompt went.
    public struct Features: Hashable, Sendable {
        public var rows: [Row]
        public var attributedCostUSD: Double
        public var totalCostUSD: Double
        public var totalTokens: Int
        public var residualCostUSD: Double
        public var residualTokens: Int
        /// The share of Claude Code tokens attributed to a feature.
        public var coverage: Double

        public init(rows: [Row], attributedCostUSD: Double = 0, totalCostUSD: Double = 0, totalTokens: Int = 0, residualCostUSD: Double = 0,
                    residualTokens: Int = 0, coverage: Double = 0) {
            self.rows = rows
            self.attributedCostUSD = attributedCostUSD
            self.totalCostUSD = totalCostUSD
            self.totalTokens = totalTokens
            self.residualCostUSD = residualCostUSD
            self.residualTokens = residualTokens
            self.coverage = coverage
        }
    }

    /// One experimental setting's cohorts and the comparison between them.
    public struct Experiment: Hashable, Sendable, Identifiable {
        public struct Cohort: Hashable, Sendable {
            public var sessions: Int
            public var costUSD: Double
            public var tokens: Int
            public var apiCalls: Int
            public var costPerCall: Double?
            public var costPerSession: Double?
            public var tokensPerCall: Double?

            public init(sessions: Int, costUSD: Double, tokens: Int = 0, apiCalls: Int = 0, costPerCall: Double? = nil,
                        costPerSession: Double? = nil, tokensPerCall: Double? = nil) {
                self.sessions = sessions
                self.costUSD = costUSD
                self.tokens = tokens
                self.apiCalls = apiCalls
                self.costPerCall = costPerCall
                self.costPerSession = costPerSession
                self.tokensPerCall = tokensPerCall
            }
        }

        public struct Comparison: Hashable, Sendable {
            public var comparable: Bool
            /// `too_few` or `no_baseline` when not comparable.
            public var reason: String?
            public var minSessions: Int
            public var minCalls: Int
            public var costPerCallChange: Double?
            public var costPerSessionChange: Double?
            public var tokensPerCallChange: Double?

            public init(comparable: Bool, reason: String? = nil, minSessions: Int = 0, minCalls: Int = 0, costPerCallChange: Double? = nil,
                        costPerSessionChange: Double? = nil, tokensPerCallChange: Double? = nil) {
                self.comparable = comparable
                self.reason = reason
                self.minSessions = minSessions
                self.minCalls = minCalls
                self.costPerCallChange = costPerCallChange
                self.costPerSessionChange = costPerSessionChange
                self.tokensPerCallChange = tokensPerCallChange
            }
        }

        public struct PairedRoot: Hashable, Sendable, Identifiable {
            public var agentRoot: String
            public var off: Cohort
            public var on: Cohort
            public var costPerCallChange: Double?
            public var id: String { agentRoot }

            public init(agentRoot: String, off: Cohort, on: Cohort, costPerCallChange: Double? = nil) {
                self.agentRoot = agentRoot
                self.off = off
                self.on = on
                self.costPerCallChange = costPerCallChange
            }
        }

        public var key: String
        public var title: String
        public var description: String?
        /// nil when unknown.
        public var currentValue: Bool?
        public var landedAt: Date?
        public var taggedSessions: Int
        public var taggedBackfilled: Int
        public var taggedObserved: Int
        public var off: Cohort
        public var on: Cohort
        public var mixed: Cohort
        public var unknown: Cohort
        public var comparison: Comparison
        public var pairedRoots: [PairedRoot]
        public var id: String { key }

        public init(key: String, title: String, description: String? = nil, currentValue: Bool? = nil, landedAt: Date? = nil,
                    taggedSessions: Int = 0, taggedBackfilled: Int = 0, taggedObserved: Int = 0, off: Cohort, on: Cohort,
                    mixed: Cohort = Cohort(sessions: 0, costUSD: 0), unknown: Cohort = Cohort(sessions: 0, costUSD: 0),
                    comparison: Comparison, pairedRoots: [PairedRoot] = []) {
            self.key = key
            self.title = title
            self.description = description
            self.currentValue = currentValue
            self.landedAt = landedAt
            self.taggedSessions = taggedSessions
            self.taggedBackfilled = taggedBackfilled
            self.taggedObserved = taggedObserved
            self.off = off
            self.on = on
            self.mixed = mixed
            self.unknown = unknown
            self.comparison = comparison
            self.pairedRoots = pairedRoots
        }
    }

    /// Dollars per minute of elapsed session time for one harness + model.
    public struct BurnRate: Hashable, Sendable, Identifiable {
        public var harness: String
        public var model: String
        public var usdPerMinute: Double
        public var usdPerHour: Double
        public var sampleSessionCount: Int
        public var sampleMinutes: Double?
        public var computedAt: Date?
        public var id: String { "\(harness)/\(model)" }

        public init(harness: String, model: String, usdPerMinute: Double, usdPerHour: Double, sampleSessionCount: Int,
                    sampleMinutes: Double? = nil, computedAt: Date? = nil) {
            self.harness = harness
            self.model = model
            self.usdPerMinute = usdPerMinute
            self.usdPerHour = usdPerHour
            self.sampleSessionCount = sampleSessionCount
            self.sampleMinutes = sampleMinutes
            self.computedAt = computedAt
        }
    }

    public var from: Date?
    public var to: Date?
    /// The slice the server computed over, as it read the request.
    public var scope: CostScope
    public var totals: Totals
    public var coverage: Coverage?
    public var breakdown: [Component]
    public var days: [Day]
    public var agentRoots: [Row]
    public var models: [Row]
    public var threadKinds: [Row]
    public var runtimes: [Row]
    public var adhocSources: [Row]
    public var features: Features?
    /// Fleet pages only; a narrowed page has none.
    public var experiments: [Experiment]
    public var topSessions: [TopSession]
    public var unpricedModels: [String]
    /// Fleet pages only, and current rates rather than the window's.
    public var burnRates: [BurnRate]

    public var totalUSD: Double { totals.costUSD }

    public init(from: Date? = nil, to: Date? = nil, scope: CostScope = .fleet, totals: Totals, coverage: Coverage? = nil,
                breakdown: [Component] = [], days: [Day] = [], agentRoots: [Row] = [], models: [Row] = [], threadKinds: [Row] = [],
                runtimes: [Row] = [], adhocSources: [Row] = [], features: Features? = nil, experiments: [Experiment] = [],
                topSessions: [TopSession] = [], unpricedModels: [String] = [], burnRates: [BurnRate] = []) {
        self.from = from
        self.to = to
        self.scope = scope
        self.totals = totals
        self.coverage = coverage
        self.breakdown = breakdown
        self.days = days
        self.agentRoots = agentRoots
        self.models = models
        self.threadKinds = threadKinds
        self.runtimes = runtimes
        self.adhocSources = adhocSources
        self.features = features
        self.experiments = experiments
        self.topSessions = topSessions
        self.unpricedModels = unpricedModels
        self.burnRates = burnRates
    }

    /// Read from `GET /api/v1/costs`.
    public static func parse(_ data: Data) throws -> CostSnapshot {
        guard let root = JSONObject(try JSONSerialization.jsonObject(with: data)) else { throw ZimmerError.decoding("costs: not an object") }
        let window = root.object("window")
        // `session_id` wins when both are set, as the server narrows.
        let scopeJSON = root.object("scope")
        let scope: CostScope
        if let session = scopeJSON?.int("session_id") {
            scope = .session(session)
        } else if let agentRoot = scopeJSON?.string("agent_root") {
            scope = .agentRoot(agentRoot)
        } else {
            scope = .fleet
        }
        let totals = root.object("totals")
        return CostSnapshot(
            from: window?.date("from"), to: window?.date("to"), scope: scope,
            totals: Totals(costUSD: totals?.double("cost_usd") ?? 0, sessionCostUSD: totals?.double("session_cost_usd") ?? 0,
                           adhocCostUSD: totals?.double("adhoc_cost_usd") ?? 0, tokens: totals?.int("total_tokens") ?? 0,
                           apiCalls: totals?.int("api_calls") ?? 0),
            coverage: root.object("ledger_coverage").map(coverage),
            breakdown: root.objects("cost_breakdown").compactMap { row in
                guard let component = row.string("component") else { return nil }
                return Component(component: component, costUSD: row.double("cost_usd") ?? 0, share: row.double("share") ?? 0)
            },
            days: root.objects("by_day").compactMap { day in
                guard let name = day.string("day") else { return nil }
                return Day(day: name, costUSD: day.double("cost_usd") ?? 0, sessionCostUSD: day.double("session_cost_usd"),
                           adhocCostUSD: day.double("adhoc_cost_usd"), tokens: day.int("tokens"), apiCalls: day.int("api_calls"),
                           roots: rows(day.objects("roots"), label: "name"), models: rows(day.objects("models"), label: "name"))
            },
            agentRoots: rows(root.objects("by_agent_root"), label: "agent_root", details: "features", detailLabel: "feature"),
            models: rows(root.objects("by_model"), label: "model"),
            threadKinds: rows(root.objects("by_thread_kind"), label: "kind"),
            runtimes: rows(root.objects("by_runtime"), label: "runtime"),
            adhocSources: rows(root.objects("by_adhoc_source"), label: "source"),
            features: root.object("by_feature").map(features),
            experiments: root.objects("by_experiment").compactMap(experiment),
            topSessions: root.objects("top_sessions").compactMap { row in
                guard let id = row.int("session_id") else { return nil }
                return TopSession(sessionID: id, costUSD: row.double("cost_usd") ?? 0, tokens: row.int("tokens"), title: row.string("title"),
                                  apiCalls: row.int("api_calls"))
            },
            unpricedModels: root.strings("unpriced_models"),
            burnRates: root.objects("burn_rates").compactMap { rate in
                guard let harness = rate.string("harness"), let model = rate.string("model") else { return nil }
                return BurnRate(harness: harness, model: model, usdPerMinute: rate.double("usd_per_minute") ?? 0,
                                usdPerHour: rate.double("usd_per_hour") ?? 0, sampleSessionCount: rate.int("sample_session_count") ?? 0,
                                sampleMinutes: rate.double("sample_minutes"), computedAt: rate.date("computed_at"))
            }
        )
    }

    /// The by-X rows each name their label differently (`agent_root`, `model`, `kind`…).
    private static func rows(_ objects: [JSONObject], label: String, details: String? = nil, detailLabel: String = "name") -> [Row] {
        objects.compactMap { object in
            guard let name = object.string(label) else { return nil }
            let nested = details.map { rows(object.objects($0), label: detailLabel) } ?? []
            return Row(label: name, costUSD: object.double("cost_usd") ?? 0, tokens: object.int("tokens"), apiCalls: object.int("api_calls"), details: nested)
        }
    }

    static func coverage(_ json: JSONObject) -> Coverage {
        Coverage(status: json.string("status") ?? "never_run", complete: json.bool("complete") ?? false, progressPct: json.int("progress_pct"),
                 directoriesDone: json.int("directories_done"), directoriesTotal: json.int("directories_total"), filesScanned: json.int("files_scanned"),
                 finishedAt: json.date("finished_at"), lastRanAt: json.date("last_ran_at"), lastError: json.string("last_error"),
                 coversSince: json.date("covers_since"), coversUntil: json.date("covers_until"))
    }

    private static func features(_ json: JSONObject) -> Features {
        Features(rows: rows(json.objects("rows"), label: "feature"), attributedCostUSD: json.double("attributed_cost_usd") ?? 0,
                 totalCostUSD: json.double("total_cost_usd") ?? 0, totalTokens: json.int("total_tokens") ?? 0,
                 residualCostUSD: json.double("residual_cost_usd") ?? 0, residualTokens: json.int("residual_tokens") ?? 0,
                 coverage: json.double("coverage") ?? 0)
    }

    private static func cohort(_ json: JSONObject?) -> Experiment.Cohort {
        Experiment.Cohort(sessions: json?.int("sessions") ?? 0, costUSD: json?.double("cost_usd") ?? 0, tokens: json?.int("tokens") ?? 0,
                          apiCalls: json?.int("api_calls") ?? 0, costPerCall: json?.double("cost_per_call"),
                          costPerSession: json?.double("cost_per_session"), tokensPerCall: json?.double("tokens_per_call"))
    }

    private static func experiment(_ json: JSONObject) -> Experiment? {
        guard let key = json.string("key") else { return nil }
        let cohorts = json.object("cohorts")
        let comparison = json.object("comparison")
        let sources = json.object("tagged_by_source")
        return Experiment(
            key: key, title: json.string("title") ?? key, description: json.string("description"), currentValue: json.bool("current_value"),
            landedAt: json.date("landed_at"), taggedSessions: json.int("tagged_sessions") ?? 0,
            taggedBackfilled: sources?.int("backfilled") ?? 0, taggedObserved: sources?.int("observed") ?? 0,
            off: cohort(cohorts?.object("off")), on: cohort(cohorts?.object("on")), mixed: cohort(cohorts?.object("mixed")),
            unknown: cohort(cohorts?.object("unknown")),
            comparison: Experiment.Comparison(comparable: comparison?.bool("comparable") ?? false, reason: comparison?.string("reason"),
                                              minSessions: comparison?.int("min_sessions") ?? 0, minCalls: comparison?.int("min_calls") ?? 0,
                                              costPerCallChange: comparison?.double("cost_per_call_change"),
                                              costPerSessionChange: comparison?.double("cost_per_session_change"),
                                              tokensPerCallChange: comparison?.double("tokens_per_call_change")),
            pairedRoots: json.objects("paired_roots").compactMap { row in
                guard let agentRoot = row.string("agent_root") else { return nil }
                return Experiment.PairedRoot(agentRoot: agentRoot, off: cohort(row.object("off")), on: cohort(row.object("on")),
                                             costPerCallChange: row.double("cost_per_call_change"))
            }
        )
    }
}
