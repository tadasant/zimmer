import Foundation

/// The web page's *Scheduling class* select (`_session_metadata.html.erb`): derive the class
/// from the session's genesis, or choose priority or spot for this one session.
public enum SchedulingClassChoice: String, CaseIterable, Hashable, Sendable, Identifiable {
    case derive, priority, spot

    public var id: String { rawValue }
}

extension SessionSummary {
    /// What the web select shows as chosen: *Derive it* when no class was chosen for this session.
    public var schedulingClassChoice: SchedulingClassChoice {
        switch schedulingClass {
        case "priority": return .priority
        case "spot": return .spot
        default: return .derive
        }
    }

    /// The select's words for `choice`. *Derive it* names the class the genesis gives, which is
    /// the class in force while none is chosen. While one is, the API reports only that one,
    /// so it does not say what the genesis would give, and neither does this.
    public func schedulingClassLabel(_ choice: SchedulingClassChoice) -> String {
        switch choice {
        case .derive:
            guard schedulingClassDerived, let priorityClass, !priorityClass.isEmpty else { return "Derive it" }
            return "Derive it (\(priorityClass))"
        case .priority: return "Priority"
        case .spot: return "Spot"
        }
    }

    /// The web page's words beside the precedence field.
    public var precedenceHint: String {
        isPriority
            ? "Unused while this session is priority; it applies if it is demoted to spot."
            : "Higher is worked first — see the Ranked view."
    }
}

/// `SessionPrecedence::MIN` to `MAX`: the precedences the server takes.
public enum Precedence {
    public static let range = -1_000_000_000...1_000_000_000

    /// What was typed, as a precedence the server takes, or nil: a whole number, within range.
    public static func parse(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(value) else { return nil }
        return value
    }
}
