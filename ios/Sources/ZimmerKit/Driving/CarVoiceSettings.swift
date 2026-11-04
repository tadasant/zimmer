import Foundation

/// What the car's voice settings panel shows: the Live settings that really change what a call
/// does, as rows a driver can read at a glance, each with a few discrete choices. CarPlay has no
/// slider.
///
/// They are the server's `LiveSetting` row, the one the live model writes with
/// `update_live_settings` when asked out loud and every other writer writes too. So a value
/// pushed too far by voice is the value shown here, and a choice made here is the value the next
/// call is minted from.
///
/// **The panel shows only what a call would act on.** Under Semantic turn detection, the
/// default, `RealtimeSession` sends OpenAI eagerness and nothing else: the threshold and the
/// pause go nowhere, so they have no row until the driver picks Silence, and Eagerness has none
/// under Silence. A value hidden that way is still cleared by Reset to defaults.
///
/// **The first row is the reply cap, because that is what has actually broken a call.**
/// `voice_max_output_tokens` at 180 cut off 12 of one call's 13 replies, and the tool calls with
/// them. Listening is the one row a car call does not read, and it says so: a call that has been
/// on the car is built as Always whatever it says, until it hangs up. It is here for the calls
/// started on the phone, where a gated mode drops the lines it does not take to be meant for it.
public struct CarVoiceSettings: Sendable, Equatable {
    public struct Choice: Sendable, Equatable, Identifiable {
        public let title: String
        /// What the choice does, when that takes words: the part of the server's label after
        /// the dash, or a preset's note.
        public let note: String?
        /// What to write: the setting's value, or null to put it back on its default.
        public let value: JSONValue
        public let isCurrent: Bool

        public var id: String { title }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let key: String
        public let title: String
        public let detail: String
        public let choices: [Choice]

        public var id: String { key }
    }

    /// The server's name for each turn detection, and which setting belongs to which.
    static let silence = "server_vad"
    static let semantic = "semantic_vad"
    static let turnDetectionKey = "voice_turn_detection"

    private struct Knob {
        let key: String
        let title: String
        /// The turn detection that sends it to OpenAI; nil for one that goes whichever is on.
        var onlyWith: String?
        /// A number's choices and any note on them. An enum takes the server's options.
        var presets: [(value: Double, note: String?)] = []
        var unit = ""
        /// What a setting with no default reads as when it is unset.
        var unset = "Off"
        /// What the driver has to know to read the value.
        var caveat: String?
    }

    private static let knobs = [
        Knob(key: "voice_max_output_tokens", title: "Reply length cap",
             presets: [(512, nil), (1_024, nil), (2_048, nil)], unset: "No cap"),
        Knob(key: turnDetectionKey, title: "Turn detection"),
        Knob(key: "voice_vad_eagerness", title: "Eagerness", onlyWith: semantic),
        Knob(key: "voice_vad_threshold", title: "Speech threshold", onlyWith: silence,
             presets: [(0.3, "Hears quiet speech"), (0.5, nil), (0.7, nil), (0.9, "Loud speech only")]),
        Knob(key: "voice_vad_silence_duration_ms", title: "Pause that ends a turn", onlyWith: silence,
             presets: [(300, nil), (500, nil), (800, nil), (1_200, nil)], unit: " ms"),
        Knob(key: "voice_listening", title: "Listening", caveat: "Phone only"),
        Knob(key: "voice_noise_reduction", title: "Noise reduction"),
        Knob(key: "voice_speed", title: "Speaking speed", presets: [(0.8, nil), (1.0, nil), (1.2, nil)], unit: "×"),
    ]

    /// What Reset to defaults puts back: every row, shown or not, and the one fine-tuning setting
    /// too small to earn a row. Not the models or the voice, which are somebody's choice and not
    /// a knob pushed too far; not Call telemetry; and not the guidance, which is somebody's
    /// writing and has its own history.
    public static let resetKeys = knobs.map(\.key) + ["voice_vad_prefix_padding_ms"]

    public let rows: [Row]
    /// What Reset to defaults writes: the settings away from their default, each back on it.
    public let resetChanges: [String: JSONValue]

    public var canReset: Bool { !resetChanges.isEmpty }

    public init(_ settings: LiveSettings) {
        let detection = settings.value(Self.turnDetectionKey).string ?? Self.semantic
        rows = Self.knobs.compactMap { knob in
            // An older server does not name it: nothing to show, nothing to write. And one the
            // call would not send to OpenAI has no row: a control for it would change nothing.
            guard let field = settings.fields.first(where: { $0.key == knob.key }),
                  knob.onlyWith == nil || knob.onlyWith == detection else { return nil }
            let value = settings.value(knob.key)
            var detail = Self.shown(value, field: field, knob: knob)
            // A detail is cut at about forty characters, and the caveat is the half that matters.
            if let caveat = Self.caveat(knob, detection: detection) {
                detail += ". \(caveat)"
            } else if !settings.isOverridden(knob.key) {
                detail += " (default)"
            }
            return Row(key: knob.key, title: knob.title, detail: detail,
                       choices: field.type == .choice ? Self.choices(enumOf: field, value: value, knob: knob)
                                                      : Self.choices(numberOf: field, value: value, knob: knob))
        }
        resetChanges = Dictionary(uniqueKeysWithValues: Self.resetKeys.filter(settings.isOverridden).map { ($0, JSONValue.null) })
    }

    // MARK: - Words

    /// A server label up to its explanation, capitalized: "Semantic — waits until you sound
    /// finished" is "Semantic", "auto (medium)" is "Auto", and that is all a row has room for.
    static func short(_ label: String) -> String {
        sentence(label.components(separatedBy: " — ")[0].components(separatedBy: " (")[0])
    }

    private static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func shown(_ value: JSONValue, field: LiveSettingField, knob: Knob) -> String {
        if value == .null { return knob.unset }
        return field.type == .choice ? short(field.label(for: value)) : value.liveSettingText + knob.unit
    }

    /// Why the threshold is missing is said where the driver would go to bring it back.
    private static func caveat(_ knob: Knob, detection: String) -> String? {
        if knob.key == turnDetectionKey, detection == semantic { return "Threshold needs Silence" }
        return knob.caveat
    }

    // MARK: - Choices

    private static func choices(enumOf field: LiveSettingField, value: JSONValue, knob: Knob) -> [Choice] {
        let current = value == .null ? nil : value.liveSettingText
        var choices = field.options.map { option in
            let isDefault = field.defaultValue?.liveSettingText == option.value
            let parts = option.label.components(separatedBy: " — ")
            let name = short(option.label)
            return Choice(title: isDefault ? "\(name) (default)" : name, note: parts.count > 1 ? sentence(parts[1]) : nil,
                          value: isDefault ? .null : .string(option.value), isCurrent: option.value == current)
        }
        // A setting with no default is off when unset, and off is one of its choices.
        if field.defaultValue == nil {
            choices.insert(Choice(title: "\(knob.unset) (default)", note: nil, value: .null, isCurrent: current == nil), at: 0)
        }
        return choices
    }

    /// The presets the server's range allows, its default, and the value in force, in order. The
    /// value in force is there even when it is none of them (180, set by voice), so the list
    /// always shows where the setting is now. The range is the server's, so a floor raised there
    /// takes the presets under it off this list with no change here.
    private static func choices(numberOf field: LiveSettingField, value: JSONValue, knob: Knob) -> [Choice] {
        let current = value.number
        let fallback = field.defaultValue?.number
        func same(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.000_1 } ?? false }

        var numbers = knob.presets.map(\.value).filter { (field.min ?? -.infinity)...(field.max ?? .infinity) ~= $0 }
        for extra in [fallback, current].compactMap({ $0 }) where !numbers.contains(where: { same($0, extra) }) {
            numbers.append(extra)
        }
        let list = numbers.sorted().map { number in
            var title = JSONValue.number(number).liveSettingText + knob.unit
            let isDefault = same(fallback, number)
            if isDefault { title += " (default)" }
            return Choice(title: title, note: knob.presets.first { same($0.value, number) }?.note,
                          value: isDefault ? .null : .number(number), isCurrent: same(current, number))
        }
        guard fallback == nil else { return list }
        return [Choice(title: "\(knob.unset) (default)", note: nil, value: .null, isCurrent: current == nil)] + list
    }
}

/// The call the gear ended, to bring back when the panel closes.
///
/// `CarPlayLive` reads the call a main-queue turn after it changes, so everything here is asked of
/// the call as it is now and never of the value a sink was handed: a state from just before the
/// gear can arrive after the panel went up.
public struct CarCallComeback: Sendable, Equatable {
    /// The conversation to call again. Nil once the driver asked for a fresh start with Talk to
    /// Zimmer, which picks the conversation itself.
    public private(set) var conversation: Int?
    /// A driver who muted the call comes back muted, however many tries that takes.
    public private(set) var muted: Bool

    /// Nil when there is no call to come back to: the screen stays tappable for a moment after
    /// End, and a gear tapped then must not redial a call the driver ended.
    public init?(conversation: Int?, callIsActive: Bool, muted: Bool) {
        guard callIsActive, let conversation else { return nil }
        self.conversation = conversation
        self.muted = muted
    }

    public var wantsCall: Bool { conversation != nil }

    public mutating func talkTapped() {
        conversation = nil
    }

    /// The driver muted or unmuted the call that came back, before OpenAI answered on it. Asked
    /// of the live call only: hanging up resets its mute, and that is not the driver's choice.
    public mutating func muteChanged(_ muted: Bool, callIsActive: Bool) {
        guard callIsActive else { return }
        self.muted = muted
    }

    /// The call came back and OpenAI has answered on it, so nothing is left to bring back.
    /// Listening is not proof enough: nothing has been said on the new call yet, and one that
    /// fails there is still a retry of this comeback.
    public func isSpent(by current: LiveVoiceState) -> Bool {
        switch current {
        case .thinking, .speaking, .working: true
        case .idle, .connecting, .listening: false
        }
    }
}

/// The panel behind the gear: which page it is on, and its reads and writes. Every write goes
/// through `LiveAPI`, the app's sign-in to `PATCH /api/v1/live/settings`, into the same
/// `LiveConversations::SettingsUpdate` every other writer goes through, and the row it answers
/// with is what the panel shows next.
///
/// One write at a time: a tap during one is ignored, and `settled()` is what closing the panel
/// waits on, so a new call never reads the row ahead of the write the driver made.
@MainActor
public final class CarVoiceSettingsModel {
    public enum Page: Equatable, Sendable {
        case settings
        /// One row's choices, by its key.
        case choices(String)
    }

    public private(set) var settings: CarVoiceSettings?
    public private(set) var page = Page.settings
    /// What went wrong with the last read or write, for the panel's first line.
    public private(set) var problem: String?
    public private(set) var saving = false
    /// Anything above changed: draw again.
    public var onChange: (() -> Void)?
    /// A write landed, naming what it changed.
    public var onWritten: ((String) -> Void)?

    private let api: any LiveAPI
    /// The last write failed. The next write clears it.
    public private(set) var writeFailed = false
    private var write: Task<Void, Never>?

    public init(api: any LiveAPI) {
        self.api = api
    }

    /// The row on the current page, when the page is one row's choices.
    public var openRow: CarVoiceSettings.Row? {
        guard case let .choices(key) = page else { return nil }
        return settings?.rows.first { $0.key == key }
    }

    public func load() async {
        problem = nil
        onChange?()
        do {
            settings = CarVoiceSettings(try await api.liveSettings())
        } catch {
            problem = Self.words(error)
        }
        onChange?()
    }

    public func open(_ row: CarVoiceSettings.Row) {
        guard !row.choices.isEmpty else { return }
        page = .choices(row.key)
        onChange?()
    }

    public func back() {
        page = .settings
        onChange?()
    }

    public func choose(_ choice: CarVoiceSettings.Choice) {
        guard let row = openRow else { return }
        guard !choice.isCurrent else { return back() }
        apply([row.key: choice.value], what: row.key)
    }

    /// Back to the defaults, from the row as last read, whatever put it there.
    public func reset() {
        guard let settings, settings.canReset else { return }
        apply(settings.resetChanges, what: "reset")
    }

    /// Every write the driver made has been answered.
    public func settled() async {
        await write?.value
    }

    private func apply(_ changes: [String: JSONValue], what: String) {
        guard !saving else { return }
        saving = true
        problem = nil
        writeFailed = false
        onChange?()
        write = Task { [api] in
            do {
                self.settings = CarVoiceSettings(try await api.updateLiveSettings(changes))
                self.page = .settings
                self.onWritten?(what)
            } catch {
                self.problem = "Not saved: \(Self.words(error))"
                self.writeFailed = true
            }
            self.saving = false
            self.onChange?()
        }
    }

    private static func words(_ error: Error) -> String {
        (error as? ZimmerError)?.userMessage ?? "Couldn't reach Zimmer."
    }
}
