import Foundation

/// The parts of the session page its pinned strip jumps between, in the page's order. The
/// hierarchy and the human messages are rows of the details card, above the conversation, so
/// on a long transcript they sit far off the top: the strip keeps them a tap away.
public enum SessionPageSection: String, CaseIterable, Identifiable, Sendable {
    case overview, hierarchy, humanMessages, transcript

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .overview: return "Overview"
        case .hierarchy: return "Hierarchy"
        case .humanMessages: return "Human messages"
        case .transcript: return "Transcript"
        }
    }

    /// The sections this session's page draws: the hierarchy and the human messages only when
    /// the details card has their rows, so a chip never jumps to nothing.
    public static func available(in detail: SessionDetail, hasConversation: Bool) -> [SessionPageSection] {
        var sections: [SessionPageSection] = [.overview]
        if let hierarchy = detail.hierarchy, hierarchy.isWorthShowing { sections.append(.hierarchy) }
        if !detail.humanMessages.isEmpty || !detail.captureGaps.isEmpty { sections.append(.humanMessages) }
        if hasConversation { sections.append(.transcript) }
        return sections
    }

    /// The section being read: the last of `sections` whose top has scrolled up to the strip,
    /// or the first when none has.
    public static func current(reached: Set<SessionPageSection>, in sections: [SessionPageSection]) -> SessionPageSection {
        sections.last(where: reached.contains) ?? sections.first ?? .overview
    }
}

/// Where a reader is in the conversation, so the page and its full-screen transcript each
/// open where the other was left.
public enum ConversationReading {
    /// The message to open at: the last of `shown` whose top has scrolled above the top edge,
    /// or the first shown when none has. Nil — the newest message — when the end was in view,
    /// or when nothing is shown.
    public static func target(above: Set<Int>, atEnd: Bool, shown: [ConversationMessage]) -> Int? {
        guard !atEnd else { return nil }
        return shown.last(where: { above.contains($0.id) })?.id ?? shown.first?.id
    }
}
