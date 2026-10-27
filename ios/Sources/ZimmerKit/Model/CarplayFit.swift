import Foundation

/// CarPlay fit: whether what a session needs next from a person can be done by voice from a
/// car (`SessionCarplayFit` on the server). Presentation and triage only — it never reorders
/// the board or changes when a session runs. A mark is stale once the session has said
/// anything past the line it was written against, and a stale mark counts as untagged.
public enum CarplayFit: String, Hashable, Sendable, CaseIterable, Identifiable {
    case carplayOk = "carplay_ok"
    case laptopOnly = "laptop_only"

    public var id: String { rawValue }

    /// The server's words (`SessionCarplayFit::LABELS`).
    public var label: String {
        switch self {
        case .carplayOk: return "CarPlay-ok"
        case .laptopOnly: return "Laptop only"
        }
    }

    public var systemImage: String {
        switch self {
        case .carplayOk: return "car"
        case .laptopOnly: return "laptopcomputer"
        }
    }

    /// The reasons that go with this side, in the server's order: the classifier maps
    /// `long_read` to laptop-only, and `nothing_needed` is a session that needs nobody.
    public var reasons: [CarplayFitReason] {
        switch self {
        case .carplayOk: return [.decision, .shortAnswer, .nothingNeeded]
        case .laptopOnly: return [.longRead, .manualSteps, .credential, .localDevice]
        }
    }
}

/// What kind of human action a session is waiting on (`SessionCarplayFit::REASONS`).
public enum CarplayFitReason: String, Hashable, Sendable, CaseIterable, Identifiable {
    case decision
    case shortAnswer = "short_answer"
    case longRead = "long_read"
    case manualSteps = "manual_steps"
    case credential
    case localDevice = "local_device"
    case nothingNeeded = "nothing_needed"

    public var id: String { rawValue }

    /// The server's words (`SessionCarplayFit::REASON_LABELS`), capitalized as its form shows them.
    public var label: String {
        switch self {
        case .decision: return "A decision"
        case .shortAnswer: return "A short answer"
        case .longRead: return "A long read"
        case .manualSteps: return "Manual steps"
        case .credential: return "A credential"
        case .localDevice: return "A local device"
        case .nothingNeeded: return "Nothing"
        }
    }
}

/// A mark set by hand — from the app it is always a `human` mark, which the server lets
/// outrank every other writer at the same transcript position — or the mark cleared.
public enum CarplayFitChange: Hashable, Sendable {
    case mark(CarplayFit, reason: CarplayFitReason?)
    case clear

    /// The body of `PATCH /api/v1/sessions/:id/carplay_fit`.
    public var body: [String: String] {
        switch self {
        case let .mark(fit, reason):
            var body = ["carplay_fit": fit.rawValue]
            if let reason { body["carplay_fit_reason"] = reason.rawValue }
            return body
        case .clear:
            return ["carplay_fit": "clear"]
        }
    }

    /// What the notice says once it is done.
    public var done: String {
        switch self {
        case let .mark(fit, reason):
            return reason.map { "Marked \(fit.label) (\($0.label.lowercased()))" } ?? "Marked \(fit.label)"
        case .clear:
            return "CarPlay fit cleared"
        }
    }
}

/// What a CarPlay-fit write came to. A standing mark that outranks the write is kept: a
/// reported result, not an error, with the server's reason in `message`.
public struct CarplayFitResult: Hashable, Sendable {
    public var session: SessionSummary
    public var applied: Bool
    public var message: String?

    public init(session: SessionSummary, applied: Bool = true, message: String? = nil) {
        self.session = session
        self.applied = applied
        self.message = message
    }
}

/// The board's CarPlay-fit filter (`SessionCarplayFit::FILTER_OPTIONS`). Unset by default:
/// every row. *Not laptop-only* is the driving default — judged CarPlay-ok, plus not judged yet.
public enum CarplayFitFilter: String, Hashable, Sendable, CaseIterable, Identifiable {
    case notLaptopOnly = "not_laptop_only"
    case carplayOk = "carplay_ok"
    case laptopOnly = "laptop_only"
    case untagged

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .notLaptopOnly: return "Not laptop-only"
        case .carplayOk: return "CarPlay-ok"
        case .laptopOnly: return "Laptop only"
        case .untagged: return "Untagged"
        }
    }

    /// Whether a session belongs under this filter, as the server's `carplay_fit_filter` scope
    /// reads it: on the current mark alone, so a stale one is untagged.
    public func admits(_ session: SessionSummary) -> Bool {
        let fit = session.currentCarplayFit
        switch self {
        case .notLaptopOnly: return fit != .laptopOnly
        case .carplayOk: return fit == .carplayOk
        case .laptopOnly: return fit == .laptopOnly
        case .untagged: return fit == nil
        }
    }
}
