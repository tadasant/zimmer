import Foundation

/// The heartbeat's "Beat every" choices: `Session::HEARTBEAT_INTERVAL_OPTIONS`, which the web
/// UI's heart popout (`_session_heartbeat.html.erb`) offers as a select.
public struct HeartbeatInterval: Hashable, Sendable, Identifiable {
    public let seconds: Int
    public let label: String

    public var id: Int { seconds }

    public static let options: [HeartbeatInterval] = [
        HeartbeatInterval(seconds: 30, label: "30 seconds"),
        HeartbeatInterval(seconds: 60, label: "1 minute"),
        HeartbeatInterval(seconds: 120, label: "2 minutes"),
        HeartbeatInterval(seconds: 300, label: "5 minutes"),
        HeartbeatInterval(seconds: 600, label: "10 minutes"),
        HeartbeatInterval(seconds: 900, label: "15 minutes"),
        HeartbeatInterval(seconds: 1800, label: "30 minutes"),
        HeartbeatInterval(seconds: 3600, label: "1 hour"),
    ]

    /// `Session::HEARTBEAT_DEFAULT_INTERVAL_SECONDS`: what a session has before anyone chose.
    public static let defaultSeconds = 60

    /// The choices to offer a session beating every `seconds`: the web's, and that interval
    /// in its place among them when it is not one of them, so the picker always shows a choice.
    public static func choices(including seconds: Int) -> [HeartbeatInterval] {
        guard !options.contains(where: { $0.seconds == seconds }) else { return options }
        return (options + [HeartbeatInterval(seconds: seconds, label: label(for: seconds))]).sorted { $0.seconds < $1.seconds }
    }

    /// An interval in the web's words. The REST API and the MCP action take any whole number
    /// of seconds from 30 to a day, so one set there may not be a preset; it is still named.
    public static func label(for seconds: Int) -> String {
        if let option = options.first(where: { $0.seconds == seconds }) { return option.label }
        func unit(_ count: Int, _ name: String) -> String { "\(count) \(name)\(count == 1 ? "" : "s")" }
        if seconds % 3600 == 0 { return unit(seconds / 3600, "hour") }
        if seconds % 60 == 0 { return unit(seconds / 60, "minute") }
        return unit(seconds, "second")
    }
}

/// When a trashed session's held artifacts go for good, as the web page's header says it:
/// a date ahead, or "Deletion pending" once that date has passed and `EmptyTrashJob` has not
/// yet run.
public enum TrashExpiry: Hashable, Sendable {
    case on(Date)
    case pending
}

extension SessionSummary {
    /// The interval the heartbeat beats at, or the server's default when the field is absent.
    public var heartbeatInterval: Int { heartbeatIntervalSeconds ?? HeartbeatInterval.defaultSeconds }

    /// What the web page's header shows beside Restore on a trashed session (`trash_after`).
    /// Nil for a session not in the trash, or one with nothing held for a restore.
    public func trashExpiry(now: Date = Date()) -> TrashExpiry? {
        guard status == .archived, let trashAfter else { return nil }
        return trashAfter > now ? .on(trashAfter) : .pending
    }

    /// `Session::PRE_PROMPT_FAILURE_REASONS`: failures that can only happen before the
    /// session's first prompt was delivered.
    static let prePromptFailureReasons: Set<String> = [
        "mcp_connection_failed", "oauth_required", "spawn_failed", "git_clone_failed",
        "clone_validation_failed", "unstarted_turn_not_recoverable", "bootstrap_retries_exhausted",
    ]

    /// What the web UI asks before a restart (`SessionsHelper#restart_confirmation`), or nil
    /// when it asks nothing. A failed session restarts at once; restarting one waiting on you
    /// takes it over, so the web asks first, in one of three sentences for what the restart
    /// will actually do.
    ///
    /// The server does not send its answer, so this works it out from the fields it is derived
    /// from: `session_id`, `metadata.clone_path`, `metadata.failure_reason` and `prompt`, blank
    /// when empty or whitespace as Ruby's `present?` reads them. The server's "never ran" is a
    /// blank `session_id` *and* no stored transcript, and the API does not say whether there
    /// is a transcript: a session whose runtime id was released as stale keeps its whole
    /// transcript with a blank id. So `transcriptPresent` is what the caller knows — the session
    /// page knows whether the conversation it read has messages; the board does not (nil) — and
    /// a blank id reads as "never ran" only when the transcript is known to be absent.
    /// Otherwise the takeover is described as continuing the conversation.
    public func restartConfirmation(transcriptPresent: Bool?) -> String? {
        guard status != .failed else { return nil }
        func present(_ value: String?) -> Bool {
            !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let failedBeforeInitialPrompt = metadata?.failureReason.map(Self.prePromptFailureReasons.contains) == true
        let setupComplete = present(runtimeSessionID) && present(metadata?.clonePath)
        let neverRan = !present(runtimeSessionID) && transcriptPresent == false
        let needsRestartFromScratch = (failedBeforeInitialPrompt && !setupComplete) || (neverRan && status != .waiting)
        if needsRestartFromScratch {
            return "There is no conversation to continue here — this session's setup never finished. "
                + "Restarting throws away whatever was set up for it and re-runs the whole pipeline — a "
                + "fresh clone, a fresh process — with its original prompt. Restart it?"
        }
        if failedBeforeInitialPrompt, present(prompt) {
            return "This session's turn died before its prompt was ever delivered. Restarting takes it over "
                + "and sends that original prompt again, into a freshly spawned runtime. Restart it?"
        }
        return "This session is paused, not failed. Restarting takes it over and sends an automated "
            + "\"continue\" prompt into its existing conversation. Restart it?"
    }
}

extension VisibilityChange {
    /// The earliest a custom snooze may end: the next whole minute, which the web UI's
    /// date-time picker sets as its `min` so a time in the past cannot be chosen.
    public static func earliestCustomSnooze(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let soon = now.addingTimeInterval(60)
        return calendar.dateInterval(of: .minute, for: soon)?.start ?? soon
    }
}
