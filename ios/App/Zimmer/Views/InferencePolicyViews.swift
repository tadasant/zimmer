import SwiftUI
import ZimmerKit

/// The spot gate's form and status card, in the web page's words. Save sends the whole form,
/// as the web form posts every field; the server's refusal stays under the form.
struct SpotPolicyForm: View {
    let policy: SpotPolicy
    let save: (SpotPolicyChange) async throws -> SpotPolicy
    let saved: (SpotPolicy) -> Void
    @State private var enabled: Bool
    @State private var maxSessions: String
    @State private var fiveHour: String
    @State private var weekly: String
    @State private var preemption: Bool
    @State private var starvation: String
    @State private var error: String?
    @State private var notice: String?
    @State private var saving = false

    init(policy: SpotPolicy, save: @escaping (SpotPolicyChange) async throws -> SpotPolicy, saved: @escaping (SpotPolicy) -> Void) {
        self.policy = policy
        self.save = save
        self.saved = saved
        _enabled = State(initialValue: policy.gatingEnabled)
        _maxSessions = State(initialValue: String(policy.maxConcurrentSessions))
        _fiveHour = State(initialValue: String(policy.fiveHourReservePct))
        _weekly = State(initialValue: String(policy.weeklyReservePct))
        _preemption = State(initialValue: policy.preemptionEnabled)
        _starvation = State(initialValue: String(policy.starvationAgeCeilingHours))
    }

    var body: some View {
        form
        status
    }

    private var form: some View {
        Section {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reserve capacity for priority work, and pace spot work into the rest").font(.subheadline).foregroundStyle(Theme.ink)
                    Text("Off means spot sessions start like any other and the reserve is ignored.").font(.caption).foregroundStyle(Theme.inkSoft)
                }
            }
            .tint(Theme.accent)
            .accessibilityIdentifier("inference.spot.enabled")
            PolicyField(label: "Max sessions at once", value: $maxSessions, identifier: "inference.spot.max_concurrent_sessions",
                        hint: "Every session a worker is running counts, priority included. Only spot sessions wait for one. A turn merely queued for a worker does not count.",
                        note: policy.capNote)
            PolicyField(label: "5-hour priority reserve (%)", value: $fiveHour, identifier: "inference.spot.five_hour_reserve_pct",
                        hint: "Held back from every 5-hour window for priority sessions. Spot work fills the rest.")
            PolicyField(label: "Weekly priority reserve (%)", value: $weekly, identifier: "inference.spot.weekly_reserve_pct",
                        hint: "Held back from every week for priority sessions. Spot work fills the rest.")
            Toggle(isOn: $preemption) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let priority work take a slot.").font(.subheadline).foregroundStyle(Theme.ink)
                    Text("A priority session starting into a full fleet takes the slot off the lowest-ranked running spot session, which sleeps in the spot queue and is resumed as soon as a slot frees. Off, a priority session runs one over the limit instead.")
                        .font(.caption).foregroundStyle(Theme.inkSoft)
                }
            }
            .tint(Theme.accent)
            .accessibilityIdentifier("inference.spot.preemption_enabled")
            PolicyField(label: "Starvation age ceiling (hours)", value: $starvation, identifier: "inference.spot.starvation_age_ceiling_hours",
                        hint: "How long a spot session may be held before a turn. Past it, the starvation lane admits one session at a time past the quota ceilings, never past the limit above. 0 turns it off.")
            PolicySave(title: "Save spot policy", identifier: "inference.spot.save", saving: saving, error: error, notice: notice,
                       errorIdentifier: "inference.spot.error") { Task { await submit() } }
        } header: {
            Text("Spot vs priority").themeLabel()
        } footer: {
            Text("Every session runs as priority or spot. Priority sessions always start. Spot work fills whatever each quota window has left after the priority reserve is carved out, paced on a curve that reaches the window's end; a spot session waits when running it now would spend past that curve, past the reserve, or into a full fleet. It is deferred, never cancelled.")
                .font(.caption).foregroundStyle(Theme.inkMute)
        }
        .themeRows()
        .onChange(of: policy) { _, policy in reset(policy) }
    }

    private var status: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PolicyBadge(text: policy.decision.allowed ? "Spot sessions running" : "Spot sessions held", color: policy.decision.allowed ? Theme.success : Theme.warning)
                    if let reason = policy.decision.reason { Text(reason).font(Theme.mono).foregroundStyle(Theme.inkMute) }
                }
                if let detail = policy.decision.detail { Text(detail).font(.caption).foregroundStyle(Theme.ink) }
                Text(verbatim: startLine)
                    .font(.caption.weight(startWeight))
                    .foregroundStyle(startColor)
                ForEach(policy.hold) { line in
                    (Text(verbatim: "\(line.label): ").bold() + Text(verbatim: line.sentence))
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("inference.spot.decision")
            counts
        } header: {
            Text("The gate right now").themeLabel()
        }
        .themeRows()
    }

    @ViewBuilder
    private var counts: some View {
        if let active = policy.decision.activeSessions {
            LabeledContent("Sessions on a worker") {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: workerLine(active))
                    if let awaitingLine {
                        Text(verbatim: awaitingLine).font(.caption2).foregroundStyle(Theme.inkMute)
                    }
                }
            }
        }
        countRow("Spot sessions asleep in the queue", policy.pausedCount, policy.sessionsAsleep)
        countRow("Spot sessions preempted by priority work", policy.preemptedCount, policy.sessionsPreempted)
        countRow("Spot sessions held before a turn", policy.heldCount, heldSentence)
        countRow("Spot sessions past the starvation age ceiling", policy.starvation.starvedCount, policy.sessionsStarved)
    }

    // The sentences, worked out away from the view tree: the Release build's type checker
    // has a budget, and a ternary inside an interpolation inside a modifier chain spends it.
    private var startLine: String { "A spot session starting right now would be \(policy.decision.allowed ? "started" : "held")." }
    private var startWeight: Font.Weight { policy.decision.allowed ? .regular : .semibold }
    private var startColor: Color { policy.decision.allowed ? Theme.inkSoft : Theme.warning }

    private func workerLine(_ active: Int) -> String {
        policy.decision.fleetCap.map { "\(active) of \($0)" } ?? "\(active)"
    }

    private var awaitingLine: String? {
        guard let awaiting = policy.decision.awaitingSessions, awaiting > 0, let slots = policy.workerSlots else { return nil }
        return "\(awaiting) more waiting for one of the \(slots) worker slots · not counted"
    }

    private var heldSentence: String? {
        guard policy.overdueHoldCount > 0 else { return policy.sessionsHeld }
        return "\(policy.overdueHoldCount) overdue for a re-check. \(policy.sessionsHeld ?? "")"
    }

    private func countRow(_ label: String, _ count: Int, _ sentence: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(label) { Text(verbatim: "\(count)").monospacedDigit() }
            if let sentence, !sentence.isEmpty { Text(sentence).font(.caption).foregroundStyle(Theme.inkSoft) }
        }
        .font(.subheadline)
    }

    private func reset(_ policy: SpotPolicy) {
        enabled = policy.gatingEnabled
        maxSessions = String(policy.maxConcurrentSessions)
        fiveHour = String(policy.fiveHourReservePct)
        weekly = String(policy.weeklyReservePct)
        preemption = policy.preemptionEnabled
        starvation = String(policy.starvationAgeCeilingHours)
    }

    private func submit() async {
        guard let cap = PolicyField.whole(maxSessions, "Max sessions at once", &error),
              let five = PolicyField.whole(fiveHour, "5-hour priority reserve", &error),
              let week = PolicyField.whole(weekly, "Weekly priority reserve", &error),
              let hours = PolicyField.whole(starvation, "Starvation age ceiling", &error) else { return }
        saving = true
        defer { saving = false }
        do {
            let policy = try await save(SpotPolicyChange(enabled: enabled, fiveHourReservePct: five, weeklyReservePct: week, maxConcurrentSessions: cap,
                                                         preemptionEnabled: preemption, starvationAgeCeilingHours: hours))
            error = nil
            notice = "Spot policy saved."
            saved(policy)
            Haptics.success()
        } catch {
            notice = nil
            self.error = (error as? ZimmerError ?? .transport(error)).userMessage
            Haptics.failure()
        }
    }
}

/// The backlog top-up's form and status card.
struct FleetTopUpForm: View {
    let policy: FleetTopUp
    let save: (FleetTopUpChange) async throws -> FleetTopUp
    let saved: (FleetTopUp) -> Void
    @State private var maxSessions: String
    @State private var idle: String
    @State private var cooldown: String
    @State private var quiet: String
    @State private var error: String?
    @State private var notice: String?
    @State private var saving = false

    init(policy: FleetTopUp, save: @escaping (FleetTopUpChange) async throws -> FleetTopUp, saved: @escaping (FleetTopUp) -> Void) {
        self.policy = policy
        self.save = save
        self.saved = saved
        _maxSessions = State(initialValue: String(policy.maxRunningSessions))
        _idle = State(initialValue: String(policy.idleMinutes))
        _cooldown = State(initialValue: String(policy.minFireIntervalMinutes))
        _quiet = State(initialValue: String(policy.quietBacklogIntervalMinutes))
    }

    var body: some View {
        form
        status
    }

    private var form: some View {
        Section {
            PolicyField(label: "Top up while under", value: $maxSessions, identifier: "inference.topup.max_running_sessions",
                        hint: "Sessions a worker is running — not ones queued behind the pool waiting for one. Below this many, the fleet counts as idle enough to take more work.",
                        note: policy.ceilingNote)
            PolicyField(label: "For at least (minutes)", value: $idle, identifier: "inference.topup.idle_minutes",
                        hint: "How long it has to stay there first, so the gap between one session ending and the next starting is not mistaken for an idle fleet. Checked once a minute.")
            PolicyField(label: "At most once every (minutes)", value: $cooldown, identifier: "inference.topup.min_fire_interval_minutes", hint: cooldownHint)
            PolicyField(label: "With nothing new on the backlog (minutes)", value: $quiet, identifier: "inference.topup.quiet_backlog_interval_minutes", hint: quietHint)
            PolicySave(title: "Save top-up policy", identifier: "inference.topup.save", saving: saving, error: error, notice: notice,
                       errorIdentifier: "inference.topup.error") { Task { await submit() } }
        } header: {
            Text("Backlog top-up").themeLabel()
        } footer: {
            Text("When the fleet has room to spare, Zimmer fires the no_sessions_in_progress event so a trigger can hand it more work. Room to spare is a number: the fleet counts as idle enough while fewer than the ceiling are running on a worker. Set it to 1 and the event means nothing running.")
                .font(.caption).foregroundStyle(Theme.inkMute)
        }
        .themeRows()
        .onChange(of: policy) { _, policy in reset(policy) }
    }

    private var status: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PolicyBadge(text: policy.underCeiling ? "Room for more work" : "At its work ceiling", color: policy.underCeiling ? Theme.success : Theme.inkSoft)
                    Text(policy.state).font(Theme.mono).foregroundStyle(Theme.inkMute)
                }
                if let sentence = policy.sentence { Text(sentence).font(.caption).foregroundStyle(Theme.ink) }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("inference.topup.status")
            LabeledContent("Turns on a worker") {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: "\(policy.runningSessions) of \(policy.maxRunningSessions)")
                    Text(verbatim: headroomLine).font(.caption2).foregroundStyle(Theme.inkMute)
                    if policy.awaitingSessions > 0, let slots = policy.workerSlots {
                        Text(verbatim: "\(policy.awaitingSessions) more waiting for one of the \(slots) worker slots · not counted").font(.caption2).foregroundStyle(Theme.inkMute)
                    }
                    if policy.asleepSessions > 0 {
                        Text(verbatim: "\(policy.asleepSessions) asleep on a wake, not counted").font(.caption2).foregroundStyle(Theme.inkMute)
                    }
                }
            }
            LabeledContent("Under its ceiling since", value: policy.underCeilingSince.map { InferenceFormat.ago($0) } ?? "—")
            LabeledContent("Last fired", value: policy.lastFiredAt.map { InferenceFormat.ago($0) } ?? "never")
            LabeledContent("Next fire, at the earliest", value: policy.nextFireLine())
        } header: {
            Text("The monitor right now").themeLabel()
        } footer: {
            Text("Two more conditions hold the event off and are reported elsewhere on this page: a session parked on an auth outage, and an account pool with nothing left to serve.")
                .font(.caption).foregroundStyle(Theme.inkMute)
        }
        .font(.subheadline)
        .themeRows()
    }

    private var cooldownHint: String {
        let cadence = policy.cadence.map { " — \($0)" } ?? ""
        return "The floor between two fires\(cadence). On a fleet that stays under its ceiling this is the whole of the cadence, while the work backlog has something new."
    }

    private var quietHint: String {
        "The longer floor while the work backlog has had nothing new since the last fire, so an idle fleet with an empty backlog tops up \(policy.quietCadence ?? "less often") instead of every cooldown."
    }

    private var headroomLine: String {
        "\(policy.headroom) place\(policy.headroom == 1 ? "" : "s") of headroom"
    }

    private func reset(_ policy: FleetTopUp) {
        maxSessions = String(policy.maxRunningSessions)
        idle = String(policy.idleMinutes)
        cooldown = String(policy.minFireIntervalMinutes)
        quiet = String(policy.quietBacklogIntervalMinutes)
    }

    private func submit() async {
        guard let cap = PolicyField.whole(maxSessions, "Top up while under", &error),
              let idleMinutes = PolicyField.whole(idle, "For at least", &error),
              let cooldownMinutes = PolicyField.whole(cooldown, "At most once every", &error),
              let quietMinutes = PolicyField.whole(quiet, "With nothing new on the backlog", &error) else { return }
        saving = true
        defer { saving = false }
        do {
            let policy = try await save(FleetTopUpChange(maxRunningSessions: cap, idleMinutes: idleMinutes, minFireIntervalMinutes: cooldownMinutes,
                                                         quietBacklogIntervalMinutes: quietMinutes))
            error = nil
            notice = "Top-up policy saved."
            saved(policy)
            Haptics.success()
        } catch {
            notice = nil
            self.error = (error as? ZimmerError ?? .transport(error)).userMessage
            Haptics.failure()
        }
    }
}

/// The kinds no trigger starts, each with its class and the button that moves it, and
/// Reset to defaults.
struct GenesisClassesSection: View {
    let classes: GenesisClasses
    let move: (String, String) async throws -> GenesisClassChange
    let reset: () async throws -> GenesisClassChange
    let changed: (GenesisClasses) -> Void
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        Section {
            ForEach(classes.settable) { kind in row(kind) }
            Button("Reset to defaults") { Task { await act { try await reset() } } }
                .font(.subheadline).foregroundStyle(Theme.accent)
                .disabled(busy)
                .accessibilityIdentifier("inference.genesis.reset")
            if let notice { Text(notice).font(.caption).foregroundStyle(Theme.success).accessibilityIdentifier("inference.genesis.notice") }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.danger).accessibilityIdentifier("inference.genesis.error") }
        } header: {
            Text("Sessions no trigger started").themeLabel()
        } footer: {
            Text("Changing one of these reclassifies every session from that genesis at once, including ones that already exist — except any that were given a class of their own, which keep it. Sessions a trigger starts are not here: each trigger carries its own scheduling class.")
                .font(.caption).foregroundStyle(Theme.inkMute)
        }
        .themeRows()
    }

    private func row(_ kind: GenesisClasses.Kind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text(kind.key).font(Theme.mono).foregroundStyle(Theme.inkMute)
                }
                Spacer()
                PolicyBadge(text: kind.priorityClass, color: kind.priorityClass == "priority" ? Theme.accent : Theme.inkSoft)
                    .accessibilityIdentifier("inference.genesis.\(kind.key).class")
            }
            if kind.overridden { Text("changed from \(kind.defaultClass)").font(.caption2).foregroundStyle(Theme.warning) }
            if let description = kind.description { Text(description).font(.caption).foregroundStyle(Theme.inkSoft).lineLimit(3) }
            HStack {
                Text(verbatim: liveSessionsLine(kind)).font(.caption.monospacedDigit()).foregroundStyle(Theme.inkMute)
                Spacer()
                Button("Make \(kind.target)") { Task { await act { try await move(kind.key, kind.target) } } }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                    .disabled(busy)
                    .accessibilityIdentifier("inference.genesis.\(kind.key)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inference.genesis.row.\(kind.key)")
    }

    private func liveSessionsLine(_ kind: GenesisClasses.Kind) -> String {
        "\(kind.liveSessions) live session\(kind.liveSessions == 1 ? "" : "s")"
    }

    private func act(_ action: () async throws -> GenesisClassChange) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let change = try await action()
            error = nil
            notice = change.message
            changed(change.genesisClasses)
            Haptics.success()
        } catch {
            notice = nil
            self.error = (error as? ZimmerError ?? .transport(error)).userMessage
            Haptics.failure()
        }
    }
}

// MARK: - Shared pieces

/// A whole-number field with the web form's label under it and its hint beneath.
private struct PolicyField: View {
    let label: String
    @Binding var value: String
    let identifier: String
    let hint: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(label) {
                TextField("", text: $value)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 88)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityIdentifier(identifier)
            }
            .font(.subheadline)
            Text(hint).font(.caption).foregroundStyle(Theme.inkSoft)
            if let note { Text(note).font(.caption).foregroundStyle(Theme.warning) }
        }
    }

    /// The field as a whole number, or the local refusal the server would give on a word.
    static func whole(_ text: String, _ label: String, _ error: inout String?) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else {
            error = "\(label) must be a whole number"
            return nil
        }
        return value
    }
}

/// The Save button with the server's answer under it.
private struct PolicySave: View {
    let title: String
    let identifier: String
    let saving: Bool
    let error: String?
    let notice: String?
    let errorIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .disabled(saving)
            .accessibilityIdentifier(identifier)
        if let notice { Text(notice).font(.caption).foregroundStyle(Theme.success) }
        if let error {
            Text(error).font(.caption).foregroundStyle(Theme.danger)
                .accessibilityIdentifier(errorIdentifier)
        }
    }
}

private struct PolicyBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}
