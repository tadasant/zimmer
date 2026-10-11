import Foundation

/// What a driver can say, recognised from a dictated phrase.
///
/// Deliberately small and forgiving: a car is loud, recognition is imperfect, and a wrong
/// guess must never archive something. So only short, distinct words act, and anything
/// that is not one of them is treated as the text of a reply — which the driver hears read
/// back and confirms before it is sent. Approval is the one action taken at once, because
/// it is the common answer and it only tells the agent to carry on.
public enum VoiceCommand: Hashable, Sendable {
    /// "Yes", "approve", "go ahead", "merge it": send the canned approval.
    case approve
    /// "Archive", "done with it": archive, after a spoken confirmation.
    case archive
    /// "Next", "skip": move on without acting.
    case next
    /// "Repeat", "again": read the current one again.
    case repeatCurrent
    /// "Stop", "cancel", "that's all": end the conversation.
    case stop
    /// "Reply …" or anything else: a reply in the driver's own words.
    case reply(String)
    /// "Reply" on its own: ask what to say, and take the next phrase as the reply.
    case startReply

    public static let approvalText = "Yes, go ahead."

    public init?(_ phrase: String) {
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Recognisers add punctuation ("Yes, go ahead."): match on the words alone.
        let lower = text.lowercased()
            .unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) || $0 == "'" }
            .map(String.init).joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch lower {
        case "yes", "yeah", "approve", "approved", "go ahead", "yes go ahead", "merge it", "do it", "ship it":
            self = .approve
        case "archive", "archive it", "done with it":
            self = .archive
        case "next", "skip", "next one", "skip it":
            self = .next
        case "repeat", "again", "say again", "read it again":
            self = .repeatCurrent
        case "stop", "cancel", "that's all", "thats all", "done", "never mind", "nevermind":
            self = .stop
        case "reply", "tell it", "answer":
            self = .startReply
        default:
            for prefix in ["reply ", "tell it ", "say "] where lower.hasPrefix(prefix) {
                let body = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                self = body.isEmpty ? .next : .reply(body)
                return
            }
            self = .reply(text)
        }
    }
}

/// The voice conversation in the car, as a pure state machine: what to say, and what to do
/// when the driver answers. It touches no network, audio or CarPlay API, so every turn of
/// it is tested on Linux; `CarPlaySceneDelegate` performs the effects it returns.
///
/// One session at a time, needs-input first, at most `limit` of them. Anything that acts
/// on a session is confirmed out loud first — a misheard "archive" costs a sentence, not a
/// session.
public struct DrivingFlow: Sendable {
    public enum Effect: Hashable, Sendable {
        case speak(String)
        case followUp(sessionID: Int, text: String)
        case archive(sessionID: Int)
        case end
    }

    public enum Pending: Hashable, Sendable {
        case none
        case confirmArchive
        case confirmReply(String)
        case awaitingReply
    }

    public static let limit = 5

    public private(set) var queue: [SessionSummary]
    public private(set) var index = 0
    public private(set) var pending: Pending = .none

    public init(sessions: [SessionSummary], summaries: [Int: String] = [:]) {
        self.queue = Array(sessions.filter { $0.status == .needsInput }.prefix(Self.limit))
        self.summaries = summaries
    }

    private let summaries: [Int: String]

    public var current: SessionSummary? { queue.indices.contains(index) ? queue[index] : nil }

    /// The opening line, then the first session.
    public func opening() -> [Effect] {
        guard let first = current else {
            return [.speak("Nothing needs you right now."), .end]
        }
        let count = queue.count == 1 ? "One session needs you." : "\(queue.count) sessions need you."
        return [.speak("\(count) \(describe(first))")]
    }

    public mutating func handle(_ command: VoiceCommand) -> [Effect] {
        guard let session = current else { return [.speak("That's everything."), .end] }

        switch (pending, command) {
        case (_, .stop):
            pending = .none
            return [.speak("Okay."), .end]
        case (.awaitingReply, .reply(let text)):
            pending = .confirmReply(text)
            return [.speak("Reply: \(text). Say yes to send it.")]
        case (.awaitingReply, _):
            pending = .none
            return [.speak("Okay, nothing sent. \(prompt)")]
        case (.confirmArchive, .approve):
            pending = .none
            return [.archive(sessionID: session.id), .speak("Archived.")] + advance()
        case (.confirmReply(let text), .approve):
            pending = .none
            return [.followUp(sessionID: session.id, text: text), .speak("Sent.")] + advance()
        case (.confirmArchive, _):
            pending = .none
            return [.speak("Okay, not archived. \(prompt)")]
        case (.confirmReply, _):
            pending = .none
            return [.speak("Okay, not sent. \(prompt)")]
        case (.none, .startReply):
            pending = .awaitingReply
            return [.speak("What should I tell it?")]
        case (.none, .approve):
            return [.followUp(sessionID: session.id, text: VoiceCommand.approvalText), .speak("Told it to go ahead.")] + advance()
        case (.none, .archive):
            pending = .confirmArchive
            return [.speak("Archive \(title(session))? Say yes to confirm.")]
        case (.none, .reply(let text)):
            pending = .confirmReply(text)
            return [.speak("Reply: \(text). Say yes to send it.")]
        case (.none, .next):
            return advance()
        case (.none, .repeatCurrent):
            return [.speak(describe(session))]
        }
    }

    private mutating func advance() -> [Effect] {
        index += 1
        guard let next = current else { return [.speak("That's everything."), .end] }
        return [.speak("Next: \(describe(next))")]
    }

    private var prompt: String { "Say yes, reply, archive, or next." }

    private func title(_ session: SessionSummary) -> String { session.displayTitle }

    private func describe(_ session: SessionSummary) -> String {
        var line = title(session) + "."
        if let summary = summaries[session.id], !summary.isEmpty { line += " \(summary)" }
        return "\(line) \(prompt)"
    }
}
