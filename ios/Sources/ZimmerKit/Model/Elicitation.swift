import Foundation

/// A question an MCP server put to the person, waiting on an answer. While it waits, the
/// session sits in `needs_input` with its process still alive. The web UI draws it as the
/// "Action Approval Required" banner; the app draws the same form.
public struct PendingElicitation: Hashable, Sendable, Identifiable {
    public var id: Int
    public var requestID: String
    public var message: String
    public var toolName: String?
    public var context: String?
    public var expiresAt: Date?
    public var form: ElicitationForm

    public init(id: Int, requestID: String, message: String, toolName: String? = nil, context: String? = nil, expiresAt: Date? = nil, form: ElicitationForm) {
        self.id = id
        self.requestID = requestID
        self.message = message
        self.toolName = toolName
        self.context = context
        self.expiresAt = expiresAt
        self.form = form
    }
}

/// The three answers the protocol has. `cancel` is "dismissed without answering": the
/// server stops waiting and is told nobody decided.
public enum ElicitationAnswer: String, Sendable, CaseIterable {
    case accept, decline, cancel
}

/// The fields of a `requestedSchema`, read the way the web banner reads them: one control
/// per property, in the schema's order, by `type`. A type the banner has no control for is a
/// text field there, and here.
public struct ElicitationForm: Hashable, Sendable {
    public struct Field: Hashable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable {
            case text
            case number(integer: Bool)
            case toggle
            case choice([String])
        }

        public var key: String
        public var title: String
        public var detail: String?
        public var kind: Kind
        public var required: Bool
        public var placeholder: String?

        public var id: String { key }

        public init(key: String, title: String, detail: String? = nil, kind: Kind, required: Bool = false, placeholder: String? = nil) {
            self.key = key
            self.title = title
            self.detail = detail
            self.kind = kind
            self.required = required
            self.placeholder = placeholder
        }
    }

    public var fields: [Field]

    public init(fields: [Field]) {
        self.fields = fields
    }

    /// The form a `requestedSchema` describes, its fields in `order` (the server's
    /// `field_order`), then any it did not list, by name.
    static func make(schema: RequestedSchema?, order: [String]) -> ElicitationForm {
        let properties = schema?.properties ?? [:]
        let required = Set(schema?.required ?? [])
        let listed = order.filter { properties[$0] != nil }
        let keys = listed + properties.keys.filter { !listed.contains($0) }.sorted()
        let fields = keys.compactMap { key -> Field? in
            guard let property = properties[key] else { return nil }
            let kind: Field.Kind
            switch property.type {
            case "boolean": kind = .toggle
            case "number": kind = .number(integer: false)
            case "integer": kind = .number(integer: true)
            case "string" where !(property.enumValues ?? []).isEmpty: kind = .choice(property.enumValues ?? [])
            default: kind = .text
            }
            return Field(
                key: key,
                title: property.title ?? humanize(key),
                detail: property.description,
                kind: kind,
                required: required.contains(key),
                placeholder: property.defaultValue
            )
        }
        return ElicitationForm(fields: fields)
    }

    /// Rails' `humanize`, which the web banner labels an untitled field with: "send_to" → "Send to".
    static func humanize(_ key: String) -> String {
        let words = key.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// What an `accept` carries, as the web banner builds it: every field, an empty one as
    /// `null`, a toggle as `true`/`false`. A required field left empty is refused here, naming
    /// it, rather than sent for the MCP server to reject.
    public func content(from entries: [String: String], toggles: [String: Bool]) throws -> String {
        var object: [String: Any] = [:]
        for field in fields {
            let raw = (entries[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch field.kind {
            case .toggle:
                object[field.key] = toggles[field.key] ?? false
                continue
            case let .number(integer):
                if raw.isEmpty {
                    object[field.key] = NSNull()
                } else if integer, let value = Int(raw) {
                    object[field.key] = value
                } else if !integer, let value = Double(raw) {
                    object[field.key] = value
                } else {
                    throw ElicitationFormError.notANumber(field.title)
                }
            case .text, .choice:
                object[field.key] = raw.isEmpty ? NSNull() : raw
            }
            if field.required, raw.isEmpty { throw ElicitationFormError.missing(field.title) }
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

public enum ElicitationFormError: Error, Equatable, Sendable {
    case missing(String)
    case notANumber(String)

    public var message: String {
        switch self {
        case let .missing(title): return "\(title) is required."
        case let .notANumber(title): return "\(title) needs a number."
        }
    }
}

/// The part of a JSON Schema the form reads. Anything else in it is ignored, as the web
/// banner ignores it.
struct RequestedSchema: Decodable {
    struct Property: Decodable {
        let type: String?
        let title: String?
        let description: String?
        let enumValues: [String]?
        let defaultValue: String?

        enum CodingKeys: String, CodingKey {
            case type, title, description
            case enumValues = "enum"
            case defaultValue = "default"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            description = try? container.decodeIfPresent(String.self, forKey: .description)
            enumValues = (try? container.decodeIfPresent([Scalar].self, forKey: .enumValues))?.map(\.text)
            defaultValue = (try? container.decodeIfPresent(Scalar.self, forKey: .defaultValue))?.text
        }
    }

    /// A string, number or boolean, as the text the web banner would show for it.
    struct Scalar: Decodable {
        let text: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                text = value
            } else if let value = try? container.decode(Int.self) {
                text = String(value)
            } else if let value = try? container.decode(Double.self) {
                text = String(value)
            } else if let value = try? container.decode(Bool.self) {
                text = String(value)
            } else {
                text = ""
            }
        }
    }

    let properties: [String: Property]?
    let required: [String]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        properties = try? container.decodeIfPresent([String: Property].self, forKey: .properties)
        required = try? container.decodeIfPresent([String].self, forKey: .required)
    }

    enum CodingKeys: String, CodingKey { case properties, required }
}

/// `GET /api/v1/sessions/:id/elicitations`.
struct ElicitationsResponse: Decodable {
    struct Wire: Decodable {
        let id: Int
        let request_id: String
        let message: String
        let requested_schema: RequestedSchema?
        let field_order: [String]?
        let tool_name: String?
        let context: String?
        let expires_at: String?
    }

    let elicitations: [Wire]

    var pending: [PendingElicitation] {
        elicitations.map { wire in
            PendingElicitation(
                id: wire.id,
                requestID: wire.request_id,
                message: wire.message,
                toolName: wire.tool_name,
                context: wire.context,
                expiresAt: wire.expires_at.flatMap(ZimmerJSON.parseDate),
                form: ElicitationForm.make(schema: wire.requested_schema, order: wire.field_order ?? [])
            )
        }
    }
}
