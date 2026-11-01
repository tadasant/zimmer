import Foundation

/// The row as each action is expected to leave it. The board and the session's page show these
/// at the tap, before the server has answered, and the server's own row replaces them when it
/// does — or the row goes back to what it was when the server refuses.
extension SessionSummary {
    /// Snoozed, hidden or back on the board, as `PATCH /visibility` answers.
    public mutating func expect(_ change: VisibilityChange) {
        switch change {
        case .visible:
            visibility = .visible
            snoozedUntil = nil
        case .hidden:
            visibility = .hidden
            snoozedUntil = nil
        case let .snoozed(until):
            visibility = .snoozed
            snoozedUntil = until
        }
        effectiveVisibility = visibility
    }

    /// Moved to the trash: archived, as of now.
    public mutating func expectTrashed(at now: Date = Date()) {
        status = .archived
        archivedAt = now
    }

    /// Restored from the trash. The server picks the status from what the session was doing
    /// (`unarchive_to_needs_input` is the usual one); its answer corrects the guess.
    public mutating func expectRestored() {
        status = .needsInput
        archivedAt = nil
        trashAfter = nil
    }

    /// Restarted: waiting for a worker, then running.
    public mutating func expectRestarted() {
        status = .waiting
    }

    /// Paused: the turn ends, and the session needs input.
    public mutating func expectPaused() {
        status = .needsInput
    }

    public mutating func expectHeartbeat(enabled: Bool) {
        heartbeatEnabled = enabled
    }

    public mutating func expectHeartbeat(everySeconds seconds: Int) {
        heartbeatEnabled = true
        heartbeatIntervalSeconds = seconds
    }

    public mutating func expectTitle(_ newTitle: String) {
        title = newTitle
    }

    public mutating func expectNotes(_ newNotes: String) {
        notes = newNotes.isEmpty ? nil : newNotes
    }

    public mutating func expectGoal(_ newGoal: String) {
        goal = newGoal.isEmpty ? nil : newGoal
    }

    public mutating func expectPrecedence(_ value: Int) {
        precedence = value
    }

    /// Promoted or demoted. A demotion lands at the head of the spot queue, which the server's
    /// precedence says; until then the row keeps its own.
    public mutating func expectPriority(_ priority: Bool) {
        priorityClass = priority ? "priority" : "spot"
        schedulingClass = priorityClass
    }

    public mutating func expectModel(_ id: String) {
        if config == nil { config = SessionConfig(model: id) } else { config?.model = id }
    }

    /// An effort level chosen, or nil for the model's default.
    public mutating func expectEffort(_ level: String?) {
        var summary = effort ?? EffortSummary(level: nil)
        summary.level = level ?? summary.default
        summary.source = level == nil ? "default" : "session"
        effort = summary
    }
}
