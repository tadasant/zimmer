import Charts
import SwiftUI
import ZimmerKit

/// The web UI's Costs page, read-only, section for section: the ledger's coverage, the
/// window's tiles, where the money goes by kind of token, spend by day (tap a bar for that
/// day), by agent root with each root's context-feature split, context features, the
/// experimental settings' cohorts, by model, main thread against subagents, by runtime, ad hoc
/// calls by source, the most expensive sessions, and the burn rates the spot gate reads. The
/// window is a one-tap horizon or a calendar range, and the page narrows to one agent root or
/// one session, as the web page's drilldown does. *Sweep now* asks for the history sweep and the
/// banner follows the run until it is done.
struct CostsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var window: CostWindow = .days(7)
    @State private var scope: CostScope
    /// The narrowed session's title, when it was narrowed from a row that had one.
    @State private var scopeTitle: String?
    @State private var snapshot: CostSnapshot?
    @State private var error: ZimmerError?
    /// The calendar range's two fields, pre-filled with the window on screen, as the web
    /// form's are.
    @State private var rangeFrom = Date()
    @State private var rangeTo = Date()
    /// The day whose bar was tapped: the web chart's hover detail.
    @State private var selectedDay: String?
    /// *Sweep now* is on its way to the server.
    @State private var sweeping = false
    @State private var sweepError: ZimmerError?

    init(scope: CostScope = .fleet) {
        _scope = State(initialValue: scope)
    }

    /// What the page is reading; a change to either reloads it.
    private struct Request: Equatable {
        var window: CostWindow
        var scope: CostScope
    }

    var body: some View {
        List {
            windowPicker
            if !shownScope.isFleet { scopeBanner }
            if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            if let snapshot {
                if let coverage = snapshot.coverage { coverageBanner(coverage) }
                if snapshot.totals.apiCalls == 0 && snapshot.totals.costUSD == 0 {
                    emptyState
                } else {
                    headline(snapshot)
                    if !snapshot.unpricedModels.isEmpty { unpriced(snapshot.unpricedModels) }
                    if !snapshot.breakdown.isEmpty { breakdown(snapshot.breakdown) }
                    if !snapshot.days.isEmpty { daily(snapshot.days) }
                    agentRootRows(snapshot.agentRoots, total: snapshot.totalUSD)
                    if let features = snapshot.features { self.features(features) }
                    if scope.isFleet { experiments(snapshot.experiments) }
                    rows("By model", snapshot.models, total: snapshot.totalUSD, identifier: "costs.models", empty: "No spend in this window.")
                    rows("Main thread vs subagents", snapshot.threadKinds, total: snapshot.totalUSD, identifier: "costs.threadKinds",
                         empty: "No session spend in this window.")
                    rows("By runtime", snapshot.runtimes, total: snapshot.totalUSD, identifier: "costs.runtimes", empty: "No session spend in this window.",
                         subtitle: "By billing relationship, really: Claude Code is subscription-billed and priced at Anthropic list; Pi is metered by OpenRouter, so its share is money actually owed; Codex is subscription-billed and reads $0 here because its models are unpriced — its tokens are in the ledger, its dollars are not.")
                    rows("Ad hoc calls from Zimmer's own code", snapshot.adhocSources, total: snapshot.totalUSD, identifier: "costs.adhoc",
                         empty: shownScope.isFleet ? "No ad hoc inference recorded in this window." : "Ad hoc calls belong to no agent root, so none are counted here.")
                    topSessions(snapshot)
                    if scope.isFleet { burnRates(snapshot.burnRates) }
                }
            }
        }
        .themeGround()
        .overlay { if snapshot == nil && error == nil { LoadingState() } }
        .task(id: Request(window: window, scope: scope)) { await load() }
        // A sweep in flight: the banner follows it, as reloading the web page would, until it is done.
        .task(id: sweepInFlight) {
            while sweepInFlight, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await load()
            }
        }
        .refreshable { await load() }
        .navigationTitle("Costs")
    }

    private var sweepInFlight: Bool {
        guard let status = snapshot?.coverage?.status else { return false }
        return status == "queued" || status == "running"
    }

    /// Ask for the sweep. The answer is the run queued, or the one already in flight, and the
    /// banner shows it at once; the figures grow as it runs.
    private func sweep() async {
        guard !sweeping else { return }
        sweeping = true
        defer { sweeping = false }
        do {
            let request = try await app.api.backfillCosts()
            if let coverage = request.coverage { snapshot?.coverage = coverage }
            sweepError = nil
            Haptics.success()
        } catch {
            sweepError = error as? ZimmerError ?? .transport(error)
            Haptics.failure()
        }
    }

    // MARK: - Window and scope

    /// The web page's horizons and its calendar range, side by side: the horizons answer
    /// "what happened this week" in one tap, the range "what did that week in July cost".
    @ViewBuilder
    private var windowPicker: some View {
        Section {
            Picker("Window", selection: presetSelection) {
                ForEach(CostWindow.presets) { preset in
                    Text(preset.label).tag(preset.days)
                }
                Text("Custom").tag(0)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("costs.window")
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        }
        Section {
            DatePicker("From", selection: $rangeFrom, in: ...Date(), displayedComponents: .date)
                .accessibilityIdentifier("costs.range.from")
            DatePicker("To", selection: $rangeTo, in: ...Date(), displayedComponents: .date)
                .accessibilityIdentifier("costs.range.to")
            Button("Show This Range") { showRange() }
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("costs.range.apply")
        } footer: {
            Text("Showing \(window.label())").font(.caption).foregroundStyle(Theme.inkMute)
                .accessibilityIdentifier("costs.showing")
        }
        .font(.subheadline)
        .tint(Theme.accent)
        .themeRows()
    }

    /// The segment for the window on screen; Custom (0) for a calendar range. Choosing Custom
    /// shows the range in the two fields.
    private var presetSelection: Binding<Int> {
        Binding {
            if case let .days(days) = window { return days }
            return 0
        } set: { days in
            if days == 0 { showRange() } else { window = .days(days) }
        }
    }

    /// The two fields as a window, and the fields set to what it resolved to: swapped if
    /// they were the wrong way round, a year at most.
    private func showRange() {
        let range = CostWindow.custom(from: rangeFrom, to: rangeTo)
        if case let .range(from, to) = range {
            rangeFrom = from
            rangeTo = to
        }
        window = range
    }

    /// What the figures on screen cover, as the server read the request: until a new
    /// scope's figures arrive, the banner keeps describing the ones still showing.
    private var shownScope: CostScope {
        snapshot?.scope ?? scope
    }

    /// The drilldown's own statement of what it is, without which a narrowed page reads as a
    /// fleet page on a quiet day — and the way back to every root.
    private var scopeBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                switch shownScope {
                case let .agentRoot(root):
                    HStack(spacing: 5) {
                        Text("Agent root").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text(root).font(.system(.subheadline, design: .monospaced).weight(.semibold)).foregroundStyle(Theme.ink)
                    }
                    Text("Every figure covers this agent root only, over \(window.label()). Ad hoc calls are Zimmer's own inference, made outside any session, so they carry no agent root and are left out.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                case let .session(id):
                    Button {
                        app.path = [id]
                    } label: {
                        Text(verbatim: sessionTitle(id).map { "Session #\(id) — \($0)" } ?? "Session #\(id)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    Text("Every figure covers this session only, over \(window.label()). Ad hoc calls made about it, its generated title and push summaries, are included.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                case .fleet:
                    EmptyView()
                }
                Button("All agent roots") {
                    scope = .fleet
                    scopeTitle = nil
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.borderless)
                .padding(.top, 2)
                .accessibilityIdentifier("costs.scope.clear")
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("costs.scope")
        }
        .themeRows()
    }

    private func sessionTitle(_ id: Int) -> String? {
        scopeTitle ?? snapshot?.topSessions.first(where: { $0.sessionID == id })?.title
    }

    // MARK: - Coverage and headline

    /// How much history is in the ledger, in the web banner's words: amber until the
    /// one-time sweep has run.
    private func coverageBanner(_ coverage: CostSnapshot.Coverage) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 3) {
                Text(coverage.headline).font(.subheadline.weight(.semibold)).foregroundStyle(coverage.swept ? Theme.ink : Theme.warning)
                Text(coverageDetail(coverage)).font(.caption).foregroundStyle(Theme.inkSoft)
                if let lastError = coverage.lastError, !lastError.isEmpty {
                    Text("Last error: \(lastError)").font(.caption).foregroundStyle(Theme.danger)
                }
                Button {
                    Task { await sweep() }
                } label: {
                    HStack(spacing: 6) {
                        if sweeping { ProgressView().controlSize(.small) }
                        Text(coverage.swept ? "Re-scan history" : "Sweep now")
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                .disabled(sweeping)
                .padding(.top, 4)
                .accessibilityIdentifier("costs.sweep")
                if let sweepError {
                    Text(sweepError.userMessage).font(.caption).foregroundStyle(Theme.danger).accessibilityIdentifier("costs.sweep.error")
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("costs.coverage")
        } footer: {
            Text(coverage.swept ? "Re-scanning reads every transcript again; the ledger upserts, so nothing is counted twice."
                 : "The sweep starts on its own within five minutes; Sweep now asks for it at once.")
                .font(.caption).foregroundStyle(Theme.inkMute)
        }
        .listRowBackground(coverage.swept ? Theme.surface : Theme.warning.opacity(0.08))
    }

    private func coverageDetail(_ coverage: CostSnapshot.Coverage) -> String {
        var parts: [String] = []
        if let since = coverage.coversSince {
            parts.append("Ledger covers \(since.formatted(date: .abbreviated, time: .omitted)) onward.")
        } else {
            parts.append("Nothing recorded yet.")
        }
        if coverage.swept {
            let files = (coverage.filesScanned ?? 0) > 0 ? " (\((coverage.filesScanned ?? 0).formatted()) files)" : ""
            parts.append("Swept \(coverage.finishedAt.map { Format.age($0) == "now" ? "just now" : "\(Format.age($0)) ago" } ?? "")\(files).")
        } else if coverage.status == "running", let total = coverage.directoriesTotal, total > 0 {
            parts.append("\((coverage.directoriesDone ?? 0).formatted()) of \(total.formatted()) transcript directories swept; figures below grow as it runs. It runs itself — no action needed.")
        } else if coverage.status == "running" {
            parts.append("Reading the transcript corpus now. It runs itself — no action needed.")
        } else {
            parts.append("Older spend is missing until the sweep runs. It starts on its own within five minutes.")
        }
        return parts.joined(separator: " ")
    }

    private var emptyState: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("No usage recorded \(shownScope.isFleet ? "in this window" : "for this \(scopeNoun) in this window").")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                Text("Usage is swept out of transcripts by TokenUsageIngestionJob every ten minutes, and history is swept once by TokenUsageBackfillJob. Both run on their own; nothing here needs a shell on the box.")
                    .font(.caption).foregroundStyle(Theme.inkSoft)
            }
            .padding(.vertical, 2)
            .accessibilityIdentifier("costs.empty")
        }
        .themeRows()
    }

    private var scopeNoun: String {
        if case .session = shownScope { return "session" }
        return "agent root"
    }

    /// The four tiles: total cost, tokens, API calls, ad hoc share.
    private func headline(_ snapshot: CostSnapshot) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(snapshot.totalUSD, format: .currency(code: "USD"))
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("costs.total")
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                    tile("Tokens", Format.compact(snapshot.totals.tokens), "all buckets")
                    tile("API calls", snapshot.totals.apiCalls.formatted(), "deduped by request")
                    tile("Ad hoc share", snapshot.totals.adhocShare.formatted(.percent.precision(.fractionLength(1))), "Zimmer's own calls")
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("costs.tiles")
        } header: {
            Text(window.label()).themeLabel()
        } footer: {
            Text("Total cost at list price.").font(.caption).foregroundStyle(Theme.inkMute)
        }
        .themeRows()
    }

    private func tile(_ label: String, _ value: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(Theme.inkMute)
            Text(value).font(.system(.title3, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
            Text(hint).font(.caption2).foregroundStyle(Theme.inkMute)
        }
    }

    private func unpriced(_ models: [String]) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text("Unpriced models in this window.").font(.caption.weight(.semibold)).foregroundStyle(Theme.warning)
                Text("\(models.joined(separator: ", ")) — these contribute zero to every figure above. Add a rate in TokenPricing::RATES.")
                    .font(.caption).foregroundStyle(Theme.inkSoft)
            }
            .padding(.vertical, 2)
            .accessibilityIdentifier("costs.unpriced")
        }
        .listRowBackground(Theme.warning.opacity(0.08))
    }

    // MARK: - Breakdown and days

    /// "Where the money goes": each kind of token with its share bar.
    private func breakdown(_ components: [CostSnapshot.Component]) -> some View {
        Section {
            ForEach(components) { component in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(component.component).font(.subheadline).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(component.costUSD, format: .currency(code: "USD")).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink)
                        Text(component.share, format: .percent.precision(.fractionLength(1))).font(.caption.monospacedDigit()).foregroundStyle(Theme.inkMute)
                    }
                    ShareBar(share: component.share)
                }
            }
        } header: {
            Text("Where the money goes").themeLabel()
        } footer: {
            Text("By kind of token. Cache writes bill at 1.25× base input on the 5-minute TTL and 2× on the 1-hour one; cache reads at a tenth.")
                .font(.caption).foregroundStyle(Theme.inkMute)
        }
        .themeRows()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("costs.breakdown")
    }

    /// Spend by day as the web chart draws it, and the tapped day's detail below: sessions
    /// against ad hoc, tokens, calls, the biggest roots and models.
    private func daily(_ days: [CostSnapshot.Day]) -> some View {
        Section {
            Chart(days) { day in
                BarMark(x: .value("Day", day.day), y: .value("USD", day.costUSD))
                    .foregroundStyle(selectedDay == nil || selectedDay == day.day ? Theme.accent : Theme.accent.opacity(0.35))
                    .cornerRadius(3)
            }
            .chartXAxis(.hidden)
            .chartXSelection(value: $selectedDay)
            .frame(height: 140)
            .accessibilityLabel("Spend by day")
            .accessibilityIdentifier("costs.chart")
            if let selectedDay, let day = days.first(where: { $0.day == selectedDay }) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(day.day).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(day.costUSD, format: .currency(code: "USD")).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink)
                    }
                    Text(verbatim: [
                        day.sessionCostUSD.map { "sessions \($0.formatted(.currency(code: "USD")))" },
                        day.adhocCostUSD.map { "ad hoc \($0.formatted(.currency(code: "USD")))" },
                        day.tokens.map { "\(Format.compact($0)) tokens" },
                        day.apiCalls.map { "\($0.formatted()) calls" },
                    ].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkSoft)
                    if !day.roots.isEmpty {
                        Text(verbatim: "Roots: " + day.roots.map { "\($0.label) \($0.costUSD.formatted(.currency(code: "USD")))" }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(Theme.inkMute)
                    }
                    if !day.models.isEmpty {
                        Text(verbatim: "Models: " + day.models.map { "\(Format.modelName($0.label)) \($0.costUSD.formatted(.currency(code: "USD")))" }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(Theme.inkMute)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("costs.day")
            }
        } header: {
            Text("Spend by day").themeLabel()
        } footer: {
            Text(selectedDay == nil ? "Tap a bar for that day." : "").font(.caption).foregroundStyle(Theme.inkMute)
        }
        .themeRows()
    }

    // MARK: - Tables

    /// By agent root. On the fleet page a root narrows the whole page to itself; the folded
    /// "other (N)" bucket is several roots and so not one thing to narrow to. Under each row,
    /// the web row's drilldown: tokens, per call, share, and the estimated context-feature split.
    @ViewBuilder
    private func agentRootRows(_ rows: [CostSnapshot.Row], total: Double) -> some View {
        Section {
            if rows.isEmpty {
                Text("No session spend in this window.").font(.subheadline).foregroundStyle(Theme.inkSoft)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    if scope.isFleet && CostScope.narrowable(agentRoot: row.label) {
                        Button {
                            scope = .agentRoot(row.label)
                        } label: {
                            LabeledContent {
                                HStack(spacing: 6) {
                                    Text(row.costUSD, format: .currency(code: "USD")).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink)
                                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Theme.inkMute)
                                }
                            } label: {
                                Text(row.label).font(.subheadline).foregroundStyle(Theme.ink)
                            }
                        }
                        .accessibilityIdentifier("costs.root.\(row.label)")
                    } else {
                        rowHead(row)
                    }
                    rowDetail(row, total: total)
                    if !row.details.isEmpty {
                        Text("Estimated context-feature split").font(.caption2).foregroundStyle(Theme.inkMute)
                        FlowLayout(spacing: 6, rowSpacing: 6) {
                            ForEach(row.details) { feature in
                                Text(verbatim: "\(featureLabel(feature.label)) \(feature.costUSD.formatted(.currency(code: "USD")))\(row.costUSD > 0 ? " · \((feature.costUSD / row.costUSD).formatted(.percent.precision(.fractionLength(0))))" : "")")
                                    .font(.caption2.monospacedDigit())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .foregroundStyle(Theme.inkSoft)
                                    .background(Theme.well, in: Capsule())
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("By agent root").themeLabel()
        } footer: {
            Text(scope.isFleet ? "Tap a root to narrow the whole page to it. The feature split is estimated from transcript content, not measured; the rest of a row is the fixed prompt prefix and anything else the transcript does not record."
                 : "The feature split is estimated from transcript content, not measured.")
                .font(.caption).foregroundStyle(Theme.inkMute)
        }
        .themeRows()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("costs.roots")
    }

    private func rowHead(_ row: CostSnapshot.Row) -> some View {
        LabeledContent {
            Text(row.costUSD, format: .currency(code: "USD")).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink)
        } label: {
            Text(row.label).font(.subheadline).foregroundStyle(Theme.ink)
        }
    }

    /// The web row's drilldown, on the row: calls, tokens, per call, share, and the share bar.
    private func rowDetail(_ row: CostSnapshot.Row, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: [
                row.apiCalls.map { "\($0.formatted()) calls" },
                row.tokens.map { "\(Format.compact($0)) tokens" },
                row.perCallUSD.map { "\($0.formatted(.currency(code: "USD").precision(.fractionLength(4)))) per call" },
                total > 0 ? "\((row.costUSD / total).formatted(.percent.precision(.fractionLength(1)))) share" : nil,
            ].compactMap { $0 }.joined(separator: " · "))
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.inkMute)
            ShareBar(share: total > 0 ? row.costUSD / total : 0)
        }
    }

    @ViewBuilder
    private func rows(_ title: String, _ rows: [CostSnapshot.Row], total: Double, identifier: String, empty: String, subtitle: String? = nil) -> some View {
        Section {
            if rows.isEmpty {
                Text(empty).font(.subheadline).foregroundStyle(Theme.inkSoft)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    rowHead(row)
                    rowDetail(row, total: total)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(title).themeLabel()
        } footer: {
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.inkMute) }
        }
        .themeRows()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// Context features (estimated): what the bytes in each prompt were for, the unattributed
    /// rest as its own line, and how much of the window the estimate covers.
    private func features(_ features: CostSnapshot.Features) -> some View {
        Section {
            if features.rows.isEmpty {
                Text("No feature attribution stored for this window. It is written by TokenUsageIngestionJob alongside the usage rows, and filled in for older history by the sweep the coverage panel above reports.")
                    .font(.caption).foregroundStyle(Theme.inkSoft)
            }
            let max = features.rows.map(\.costUSD).max() ?? 0
            ForEach(features.rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(featureLabel(row.label)).font(.subheadline).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(row.costUSD, format: .currency(code: "USD")).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink)
                        Text(features.totalCostUSD > 0 ? (row.costUSD / features.totalCostUSD).formatted(.percent.precision(.fractionLength(1))) : "—")
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.inkMute)
                    }
                    ShareBar(share: max > 0 ? row.costUSD / max : 0)
                    if let tokens = row.tokens {
                        Text(verbatim: "\(Format.compact(tokens)) tok").font(.caption.monospacedDigit()).foregroundStyle(Theme.inkMute)
                    }
                }
                .padding(.vertical, 2)
            }
            if !features.rows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Unattributed").font(.subheadline).foregroundStyle(Theme.inkSoft)
                        Spacer()
                        Text(features.residualCostUSD, format: .currency(code: "USD")).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink)
                        Text(features.totalCostUSD > 0 ? (features.residualCostUSD / features.totalCostUSD).formatted(.percent.precision(.fractionLength(1))) : "—")
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.inkMute)
                    }
                    ShareBar(share: max > 0 ? min(features.residualCostUSD / max, 1) : 0, tone: Theme.inkMute)
                    Text("The fixed prompt prefix — the harness system prompt and the tool schemas of every MCP server attached to the session — plus per-request web-search charges. None of it appears in a transcript, so none of it is guessed at here.")
                        .font(.caption).foregroundStyle(Theme.inkMute)
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack {
                Text("Context features").themeLabel()
                Text("estimated").themeLabel(color: Theme.inkMute)
            }
        } footer: {
            if !features.rows.isEmpty {
                Text("\(features.coverage.formatted(.percent.precision(.fractionLength(1)))) of Claude Code tokens in this window were attributed to a feature. Estimates are scaled so the parts can never exceed a request's real totals.")
                    .font(.caption).foregroundStyle(Theme.inkMute)
            }
        }
        .themeRows()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("costs.features")
    }

    /// `mcp_schemas` → "Mcp schemas", as the web page humanizes a feature it has no label for.
    private func featureLabel(_ key: String) -> String {
        let words = key.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Experimental settings, observational: each setting's two cohorts with their sample
    /// sizes, the headline only when both sides clear the bar, and the caveats beside it.
    private func experiments(_ reports: [CostSnapshot.Experiment]) -> some View {
        Section {
            if reports.isEmpty {
                Text("No experimental settings are registered.").font(.subheadline).foregroundStyle(Theme.inkSoft)
            }
            ForEach(reports) { report in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(report.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(report.currentValue.map { $0 ? "ON" : "OFF" } ?? "unknown")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2.5)
                            .foregroundStyle(report.currentValue == true ? Theme.accent : Theme.inkSoft)
                            .background((report.currentValue == true ? Theme.accent : Theme.inkSoft).opacity(0.14), in: Capsule())
                    }
                    if let description = report.description { Text(description).font(.caption).foregroundStyle(Theme.inkSoft) }
                    if report.taggedSessions == 0 {
                        Text("No session is tagged with this setting yet. Sessions are tagged as they start, so this fills in from the next run onward.")
                            .font(.caption).foregroundStyle(Theme.inkMute)
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            cohort("off", report.off, on: false)
                            cohort("on", report.on, on: true)
                        }
                        comparison(report)
                        if report.mixed.sessions > 0 || report.unknown.sessions > 0 {
                            Text(verbatim: [
                                report.mixed.sessions > 0 ? "\(report.mixed.sessions) session\(report.mixed.sessions == 1 ? "" : "s") (\(report.mixed.costUSD.formatted(.currency(code: "USD")))) had the setting toggled mid-run — excluded from both cohorts." : nil,
                                report.unknown.sessions > 0 ? "\(report.unknown.sessions) session\(report.unknown.sessions == 1 ? "" : "s") carry no observed value — also excluded." : nil,
                            ].compactMap { $0 }.joined(separator: " "))
                            .font(.caption).foregroundStyle(Theme.inkMute)
                        }
                        if !report.pairedRoots.isEmpty {
                            DisclosureGroup {
                                ForEach(report.pairedRoots) { row in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(row.agentRoot).font(Theme.mono).foregroundStyle(Theme.ink)
                                            Spacer()
                                            Text(change(row.costPerCallChange, signed: true))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(row.costPerCallChange.map { $0 < 0 ? Theme.success : Theme.danger } ?? Theme.inkMute)
                                        }
                                        Text(verbatim: "off \(perCall(row.off.costPerCall))/call (\(row.off.sessions) sessions) → on \(perCall(row.on.costPerCall))/call (\(row.on.sessions) sessions)")
                                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.inkMute)
                                    }
                                }
                            } label: {
                                Text(verbatim: "Same agent root, both cohorts (\(report.pairedRoots.count))").font(.caption).foregroundStyle(Theme.accent)
                            }
                            .tint(Theme.accent)
                        }
                        Text(provenance(report)).font(.caption).foregroundStyle(Theme.inkMute)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack {
                Text("Experimental settings").themeLabel()
                Text("observational").themeLabel(color: Theme.inkMute)
            }
        } footer: {
            Text("Each session is tagged with what every experimental setting was when it started and when it last ran. Nothing here is a controlled experiment — the settings are global, so a cohort is whoever ran while it was on. Cost per API call is the headline because it divides out session length.")
                .font(.caption).foregroundStyle(Theme.inkMute)
        }
        .themeRows()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("costs.experiments")
    }

    private func cohort(_ name: String, _ side: CostSnapshot.Experiment.Cohort, on: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption2.weight(.semibold)).foregroundStyle(on ? Theme.accent : Theme.inkMute)
            Text(verbatim: "\(side.sessions) session\(side.sessions == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.inkSoft)
            Text(verbatim: perCall(side.costPerCall)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.ink)
            Text("per call").font(.caption2).foregroundStyle(Theme.inkMute)
            Text(verbatim: "\(side.costPerSession.map { $0.formatted(.currency(code: "USD")) } ?? "—") per session · \(side.apiCalls.formatted()) calls")
                .font(.caption2.monospacedDigit()).foregroundStyle(Theme.inkMute)
            Text(verbatim: "\(side.costUSD.formatted(.currency(code: "USD"))) total · \(side.tokensPerCall.map { "\(Format.compact(Int($0))) tok/call" } ?? "—")")
                .font(.caption2.monospacedDigit()).foregroundStyle(Theme.inkMute)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((on ? Theme.accent : Theme.inkMute).opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
    }

    private func comparison(_ report: CostSnapshot.Experiment) -> some View {
        let comparison = report.comparison
        return Group {
            if comparison.comparable, let delta = comparison.costPerCallChange {
                Text("Cost per API call is ").font(.caption).foregroundStyle(Theme.inkSoft)
                + Text("\(change(delta)) \(delta < 0 ? "lower" : "higher")").font(.caption.weight(.semibold)).foregroundStyle(delta < 0 ? Theme.success : Theme.danger)
                + Text(" with the setting on.").font(.caption).foregroundStyle(Theme.inkSoft)
                + (comparison.costPerSessionChange.map { Text(" Per session — which mostly tracks how long sessions were, not this setting — it is \(change($0)) \($0 < 0 ? "lower" : "higher").").font(.caption).foregroundStyle(Theme.inkSoft) } ?? Text(""))
            } else if comparison.reason == "no_baseline" {
                Text("No baseline to compare against. Both sides have enough sessions, but the off cohort priced at $0.00 — every model it ran has no rate configured, so there is nothing to express a change against.")
                    .font(.caption).foregroundStyle(Theme.warning)
            } else {
                Text("Not enough data to compare. A side needs at least \(comparison.minSessions) sessions and \(comparison.minCalls) API calls in this window before a percentage means anything; this one has \(report.off.sessions) session\(report.off.sessions == 1 ? "" : "s") off and \(report.on.sessions) session\(report.on.sessions == 1 ? "" : "s") on. Widen the window, or wait.")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        }
    }

    private func provenance(_ report: CostSnapshot.Experiment) -> String {
        var text: String
        if let landed = report.landedAt {
            text = "Cohorts are temporal, not randomized. This setting landed on \(landed.formatted(date: .abbreviated, time: .shortened)), so off is every session before that moment and on is every session after it."
        } else {
            text = "Cohorts are observational. Sessions are labelled with what the setting actually was while they ran, so the cohorts interleave in time — but nothing assigns work to them."
        }
        text += " \(report.taggedSessions.formatted()) session\(report.taggedSessions == 1 ? "" : "s") tagged"
        text += report.taggedBackfilled > 0
            ? " (\(report.taggedBackfilled.formatted()) inferred from dates, \(report.taggedObserved.formatted()) observed while the session ran)."
            : " — all observed while the session ran."
        return text + " Figures cover \(window.label()) only."
    }

    private func perCall(_ value: Double?) -> String {
        value.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(4))) } ?? "—"
    }

    private func change(_ value: Double?, signed: Bool = false) -> String {
        guard let value else { return "—" }
        let percent = abs(value).formatted(.percent.precision(.fractionLength(1)))
        return signed ? (value < 0 ? "−" : "+") + percent : percent
    }

    private func topSessions(_ snapshot: CostSnapshot) -> some View {
        Section {
            if snapshot.topSessions.isEmpty {
                Text("No attributed session spend in this window.").font(.subheadline).foregroundStyle(Theme.inkSoft)
            }
            ForEach(snapshot.topSessions) { top in
                topSessionRow(top)
            }
        } header: {
            Text("Most expensive sessions").themeLabel()
        } footer: {
            Text((scope.isFleet ? "Swipe a session to narrow the page to it. " : "") + "Most recent call recorded \(snapshot.coverage?.coversUntil.map { Format.age($0) == "now" ? "just now" : "\(Format.age($0)) ago" } ?? "never"). List price is not a bill — these accounts are subscription-billed, so treat this as a comparable unit across models rather than money owed.")
                .font(.caption).foregroundStyle(Theme.inkMute)
        }
        .themeRows()
    }

    private func topSessionRow(_ top: CostSnapshot.TopSession) -> some View {
        Button {
            app.path = [top.sessionID]
        } label: {
            LabeledContent {
                Text(top.costUSD, format: .currency(code: "USD")).font(.subheadline.monospacedDigit())
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = top.title, !title.isEmpty {
                        Text(title).font(.subheadline).lineLimit(1)
                    }
                    HStack(spacing: 5) {
                        Text(verbatim: "#\(top.sessionID)").font(Theme.mono)
                        if let calls = top.apiCalls {
                            Text(verbatim: "· \(calls.formatted()) calls")
                        }
                        if let tokens = top.tokens {
                            Text(verbatim: "· \(Format.compact(tokens)) tokens")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkMute)
                }
            }
        }
        .foregroundStyle(Theme.ink)
        .accessibilityIdentifier("costs.session.\(top.sessionID)")
        .swipeActions(edge: .trailing) {
            if scope.isFleet {
                Button {
                    narrow(to: top)
                } label: {
                    Label("Only This", systemImage: "scope")
                }
                .tint(Theme.Swipe.snooze)
            }
        }
        .contextMenu {
            Button { app.path = [top.sessionID] } label: { Label("Open Session", systemImage: "arrow.up.forward.app") }
            if scope.isFleet {
                Button { narrow(to: top) } label: { Label("Only This Session", systemImage: "scope") }
            }
        }
    }

    private func narrow(to top: CostSnapshot.TopSession) {
        scopeTitle = top.title
        scope = .session(top.sessionID)
    }

    /// Burn rate by harness + model: current rates over a fixed sample, not the window's.
    private func burnRates(_ rates: [CostSnapshot.BurnRate]) -> some View {
        Section {
            if rates.isEmpty {
                Text("No rates computed yet — BurnRateRecomputeJob needs sessions in the ledger before it can measure one.")
                    .font(.caption).foregroundStyle(Theme.inkSoft)
            }
            ForEach(rates) { rate in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(verbatim: "\(rate.harness) · \(Format.modelName(rate.model))").font(.subheadline).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(verbatim: "\(rate.usdPerMinute.formatted(.currency(code: "USD").precision(.fractionLength(3))))/min")
                            .font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink)
                    }
                    Text(verbatim: "\(rate.usdPerHour.formatted(.currency(code: "USD")))/hr · \(rate.sampleSessionCount) sessions")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.inkMute)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Burn rate by harness + model").themeLabel()
        } footer: {
            Text("Dollars per minute of elapsed session time, measured over the last sessions of each combination. The spot gate multiplies these by how long until it next looks to decide whether one more session fits inside the quota window. Current rates, not rates for the window above. Claude Code only: Pi and Codex spend appears in every table above this one and in none of the rates here.")
                .font(.caption).foregroundStyle(Theme.inkMute)
        }
        .themeRows()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("costs.burnRates")
    }

    private func load() async {
        do {
            let loaded = try await app.api.costs(window, scope: scope)
            // A window or scope chosen since this was asked for has its own load running.
            guard !Task.isCancelled else { return }
            snapshot = loaded
            error = nil
            if let selectedDay, !loaded.days.contains(where: { $0.day == selectedDay }) { self.selectedDay = nil }
            // A horizon fills the range's fields with its own bounds, so opening the calendar
            // starts from what is on screen.
            if !window.isCustom, let from = loaded.from, let to = loaded.to {
                rangeFrom = from
                rangeTo = to
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error as? ZimmerError ?? .transport(error)
            app.noteError(self.error!)
        }
    }
}

/// The web table's bar-in-a-cell: a row's share of the biggest row, or of the total.
private struct ShareBar: View {
    let share: Double
    var tone: Color = Theme.accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.well)
                Capsule().fill(tone).frame(width: proxy.size.width * min(max(share, 0), 1))
            }
        }
        .frame(height: 4)
    }
}
