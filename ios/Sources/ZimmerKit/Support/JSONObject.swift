import Foundation

/// A JSON object read field by field, tolerant of a missing or oddly typed value: the
/// health and costs reports are wide, hand-built hashes whose shape drifts a key at a time,
/// and one unexpected value must cost one figure, not the page.
struct JSONObject {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    init?(_ any: Any?) {
        guard let raw = any as? [String: Any] else { return nil }
        self.raw = raw
    }

    subscript(key: String) -> Any? { raw[key] }

    func object(_ key: String) -> JSONObject? { JSONObject(raw[key]) }

    func objects(_ key: String) -> [JSONObject] {
        (raw[key] as? [Any])?.compactMap(JSONObject.init) ?? []
    }

    func string(_ key: String) -> String? {
        guard let value = raw[key] else { return nil }
        if let text = value as? String { return text }
        if value is NSNull { return nil }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    func int(_ key: String) -> Int? {
        guard let number = raw[key] as? NSNumber else { return Int(raw[key] as? String ?? "") }
        return number.intValue
    }

    func double(_ key: String) -> Double? {
        guard let number = raw[key] as? NSNumber else { return Double(raw[key] as? String ?? "") }
        return number.doubleValue
    }

    func bool(_ key: String) -> Bool? {
        raw[key] as? Bool
    }

    func date(_ key: String) -> Date? {
        string(key).flatMap(ZimmerJSON.parseDate)
    }

    func strings(_ key: String) -> [String] {
        (raw[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// A `{name: count}` hash as ordered pairs, largest first then by name, as the web
    /// page's breakdown lines read.
    func counts(_ key: String) -> [(String, Int)] {
        guard let hash = raw[key] as? [String: Any] else { return [] }
        return hash.compactMap { name, value -> (String, Int)? in
            guard let number = value as? NSNumber else { return nil }
            return (name, number.intValue)
        }
        .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }

    /// A `{name: seconds}` hash as ordered pairs, oldest first.
    func ages(_ key: String) -> [(String, Double)] {
        guard let hash = raw[key] as? [String: Any] else { return [] }
        return hash.compactMap { name, value -> (String, Double)? in
            guard let number = value as? NSNumber else { return nil }
            return (name, number.doubleValue)
        }
        .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }

    /// A health section's `status`: a bare word or a `{status, message}` object.
    func status(_ key: String = "status") -> (status: String, message: String?)? {
        if let word = raw[key] as? String { return (word, nil) }
        if let object = object(key), let word = object.string("status") { return (word, object.string("message")) }
        return nil
    }
}
