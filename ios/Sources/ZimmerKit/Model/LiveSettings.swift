import Foundation

/// The Live settings: the models, voice, speaking speed and turn detection every live
/// conversation runs on, and the free-text Live mode guidance appended to the live model's
/// instructions. One global row on the server (`LiveSetting`); `GET /api/v1/live/settings`.
/// A write answers with the same shape plus `changed` and `summary`. See docs/sessions/live.md.
public struct LiveSettings: Decodable, Sendable, Equatable {
    /// Every setting's value in force: the override, or the default. A value may be a string,
    /// a number, or null ("not set").
    public let settings: [String: JSONValue]
    /// The keys set away from their default.
    public let overrides: [String]
    public let guidance: String
    public let updatedAt: Date?
    public let updatedBy: String?
    public let fields: [LiveSettingField]
    public let guidanceMaxLength: Int
    /// The newest changes first.
    public let history: [LiveSettingChange]
    /// On a write: whether anything changed.
    public let changed: Bool?
    /// On a write: what changed, in words (and any number that was clamped to its range).
    public let summary: String?

    public init(settings: [String: JSONValue], overrides: [String] = [], guidance: String = "", updatedAt: Date? = nil,
                updatedBy: String? = nil, fields: [LiveSettingField], guidanceMaxLength: Int = 8_000,
                history: [LiveSettingChange] = [], changed: Bool? = nil, summary: String? = nil) {
        self.settings = settings
        self.overrides = overrides
        self.guidance = guidance
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.fields = fields
        self.guidanceMaxLength = guidanceMaxLength
        self.history = history
        self.changed = changed
        self.summary = summary
    }

    /// The fields on one path (`text` or `voice`), in the server's order.
    public func fields(on path: String) -> [LiveSettingField] {
        fields.filter { $0.path == path }
    }

    public func value(_ key: String) -> JSONValue {
        settings[key] ?? .null
    }

    public func isOverridden(_ key: String) -> Bool {
        overrides.contains(key)
    }

    enum CodingKeys: String, CodingKey {
        case settings, overrides, guidance, fields, history, changed, summary
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case guidanceMaxLength = "guidance_max_length"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decodeIfPresent([String: JSONValue].self, forKey: .settings) ?? [:]
        overrides = try c.decodeIfPresent([String].self, forKey: .overrides) ?? []
        guidance = try c.decodeIfPresent(String.self, forKey: .guidance) ?? ""
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy)
        fields = try c.decodeIfPresent([LiveSettingField].self, forKey: .fields) ?? []
        guidanceMaxLength = try c.decodeIfPresent(Int.self, forKey: .guidanceMaxLength) ?? 8_000
        history = try c.decodeIfPresent([LiveSettingChange].self, forKey: .history) ?? []
        changed = try c.decodeIfPresent(Bool.self, forKey: .changed)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }
}

/// One setting: what it is called, which path it steers, and its choices or range.
public struct LiveSettingField: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        /// One of `options`.
        case choice = "enum"
        case float, integer
    }

    public struct Option: Decodable, Sendable, Equatable, Hashable {
        public let value: String
        public let label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    public let key: String
    /// `text` (typed turns) or `voice`.
    public let path: String
    public let type: Kind
    public let label: String
    public let help: String
    /// An enum's choices.
    public let options: [Option]
    public let min: Double?
    public let max: Double?
    /// The value a reset goes back to; nil when the default is "not set".
    public let defaultValue: JSONValue?
    /// A voice setting an open call takes mid-call (the others apply from the next call).
    public let midCall: Bool?

    public var id: String { key }

    public init(key: String, path: String, type: Kind, label: String, help: String = "", options: [Option] = [],
                min: Double? = nil, max: Double? = nil, defaultValue: JSONValue? = nil, midCall: Bool? = nil) {
        self.key = key
        self.path = path
        self.type = type
        self.label = label
        self.help = help
        self.options = options
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
        self.midCall = midCall
    }

    /// The option's label for `value`, or the value itself.
    public func label(for value: JSONValue) -> String {
        let text = value.liveSettingText
        return options.first { $0.value == text }?.label ?? text
    }

    enum CodingKeys: String, CodingKey {
        case key, path, type, label, help, options, min, max
        case defaultValue = "default"
        case midCall = "mid_call"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "text"
        // A type this version does not know reads as a choice; with no options it is edited as
        // text, which the server validates.
        type = Kind(rawValue: try c.decodeIfPresent(String.self, forKey: .type) ?? "") ?? .choice
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
        help = try c.decodeIfPresent(String.self, forKey: .help) ?? ""
        options = try c.decodeIfPresent([Option].self, forKey: .options) ?? []
        min = try c.decodeIfPresent(Double.self, forKey: .min)
        max = try c.decodeIfPresent(Double.self, forKey: .max)
        defaultValue = try c.decodeIfPresent(JSONValue.self, forKey: .defaultValue)
        midCall = try c.decodeIfPresent(Bool.self, forKey: .midCall)
    }
}

/// One recorded edit of the Live settings or the guidance: who made it (a person, or an agent
/// through MCP or a live conversation) and each key's value before and after.
public struct LiveSettingChange: Decodable, Sendable, Equatable, Identifiable {
    public struct Diff: Decodable, Sendable, Equatable {
        public let before: JSONValue?
        public let after: JSONValue?

        public init(before: JSONValue?, after: JSONValue?) {
            self.before = before
            self.after = after
        }
    }

    public let id: Int
    /// `human` or `agent`.
    public let actorKind: String
    public let actor: String
    public let liveConversationID: Int?
    public let changes: [String: Diff]
    public let createdAt: Date?

    public var byAgent: Bool { actorKind == "agent" }
    public var touchesGuidance: Bool { changes["guidance"] != nil }
    /// The keys it changed, sorted.
    public var keys: [String] { changes.keys.sorted() }

    public init(id: Int, actorKind: String, actor: String, liveConversationID: Int? = nil,
                changes: [String: Diff], createdAt: Date? = nil) {
        self.id = id
        self.actorKind = actorKind
        self.actor = actor
        self.liveConversationID = liveConversationID
        self.changes = changes
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, actor, changes
        case actorKind = "actor_kind"
        case liveConversationID = "live_conversation_id"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        actorKind = try c.decodeIfPresent(String.self, forKey: .actorKind) ?? "human"
        actor = try c.decodeIfPresent(String.self, forKey: .actor) ?? ""
        liveConversationID = try c.decodeIfPresent(Int.self, forKey: .liveConversationID)
        changes = try c.decodeIfPresent([String: Diff].self, forKey: .changes) ?? [:]
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

extension JSONValue {
    /// A setting's value as text: a whole number without its ".0", null as "".
    public var liveSettingText: String {
        switch self {
        case .null: return ""
        case let .bool(value): return value ? "true" : "false"
        case let .number(value):
            if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
            return String(value)
        case let .string(value): return value
        case .array, .object: return encoded()
        }
    }

    public var number: Double? {
        switch self {
        case let .number(value): return value
        case let .string(value): return Double(value)
        default: return nil
        }
    }

    /// The value as `JSONSerialization` takes it, whole numbers as integers.
    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .number(value):
            if value.rounded() == value, abs(value) < 1e15 { return Int(value) }
            return value
        case let .string(value): return value
        case let .array(values): return values.map(\.foundationObject)
        case let .object(object): return object.mapValues(\.foundationObject)
        }
    }
}
