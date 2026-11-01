import Foundation

/// A message of yours on its way to a session: shown under the conversation from the moment
/// it is sent, as the web composer shows a bubble before the server has it.
public struct OutgoingMessage: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// Asked of the server; no answer yet.
        case sending
        /// The server took it and delivered it: it shows in the conversation once the
        /// transcript has it.
        case delivered
        /// The server took it and queued it behind the turn in flight: it shows in the queue.
        case queued
        /// The server refused it, or could not be reached. The words are kept for another try.
        case failed(String)
    }

    public let id: UUID
    public var content: String
    /// How many photos and files went with it.
    public var attachmentCount: Int
    /// Sent with *Send Now*, ending the turn in flight.
    public var now: Bool
    public var state: State
    public var sentAt: Date
    /// How many messages the conversation held when it was sent: the transcript shows this
    /// one at a position past that.
    public var conversationTotal: Int

    public init(id: UUID = UUID(), content: String, attachmentCount: Int = 0, now: Bool = false,
                state: State = .sending, sentAt: Date = Date(), conversationTotal: Int) {
        self.id = id
        self.content = content
        self.attachmentCount = attachmentCount
        self.now = now
        self.state = state
        self.sentAt = sentAt
        self.conversationTotal = conversationTotal
    }

    public var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Why it failed, for the bubble.
    public var failure: String? {
        if case let .failed(reason) = state { return reason }
        return nil
    }
}

/// The messages sent from a session's page that the server has not yet shown back: what the
/// page draws after the conversation, and the rules for taking each one down again.
public struct OutgoingMessages: Hashable, Sendable {
    /// How long a delivered message stays on screen when the transcript never shows it — a
    /// session that failed before its process logged the message. The server has it either way.
    public static let settleAfter: TimeInterval = 120

    public private(set) var messages: [OutgoingMessage] = []

    public init() {}

    /// A message is going out. Returns its id, for `delivered`, `failed` and `take`.
    @discardableResult
    public mutating func add(_ message: OutgoingMessage) -> UUID {
        messages.append(message)
        return message.id
    }

    /// The server took the message with `id`: delivered, or queued behind the turn in flight.
    public mutating func delivered(_ id: UUID, queued: Bool) {
        update(id) { $0.state = queued ? .queued : .delivered }
    }

    /// The server refused the message with `id`, or was never reached.
    public mutating func failed(_ id: UUID, _ reason: String) {
        update(id) { $0.state = .failed(reason) }
    }

    /// Take the message with `id` off the page — to put its words back in the composer, or
    /// to send it again. Returns it, or nil when the page no longer shows it.
    public mutating func take(_ id: UUID) -> OutgoingMessage? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        return messages.remove(at: index)
    }

    /// Whether any message is still waiting on the server.
    public var hasSending: Bool { messages.contains { $0.state == .sending } }

    public var isEmpty: Bool { messages.isEmpty }

    /// Take down what the server now shows itself: a delivered message once the conversation
    /// has it at a position past where the conversation stood when it was sent, a queued one
    /// once the queue has it, and a delivered one the transcript never showed once
    /// `settleAfter` has passed. A failed message stays until a person decides about it, and
    /// one still sending stays until the server answers.
    public mutating func reconcile(conversation: Conversation?, queue: [QueuedMessage], now: Date = Date()) {
        messages.removeAll { message in
            switch message.state {
            case .sending, .failed:
                return false
            case .queued:
                return queue.contains { Self.sameWords($0.content, message.content) }
            case .delivered:
                if now.timeIntervalSince(message.sentAt) >= Self.settleAfter { return true }
                guard let conversation else { return false }
                return conversation.messages.contains { shown in
                    shown.role == .user && shown.id >= message.conversationTotal && Self.sameWords(shown.content, message.content)
                }
            }
        }
    }

    private mutating func update(_ id: UUID, _ change: (inout OutgoingMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    /// The transcript may carry the words with attachment notes or whitespace around them.
    static func sameWords(_ shown: String, _ sent: String) -> Bool {
        let shown = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        let sent = sent.trimmingCharacters(in: .whitespacesAndNewlines)
        return shown == sent || (!sent.isEmpty && shown.contains(sent))
    }
}
