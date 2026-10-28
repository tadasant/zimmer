import Foundation

/// What the car shows, worked out from the board: the sessions that need the driver, the ones
/// at work, and the words for each row. It touches no network,
/// audio or CarPlay API, so every rule is tested on Linux; the CarPlay scene renders it.
///
/// Two lists, because a driver has two questions: *does anything need me?* and *what is going
/// on?* Each is capped at what a car is guaranteed to show (`listLimit`) and ordered as the
/// board's Needs input view is: the session the person touched last comes first.
public struct DrivingBoard: Hashable, Sendable {
    /// Some cars cap a list at 12 rows; Apple's guide says to be ready for that.
    public static let listLimit = 12

    /// Needs input and failed: each something to talk through with Live Mode.
    public var needsYou: [DrivingCard]
    /// Running and waiting: at work, nothing to decide.
    public var working: [DrivingCard]
    public var needsYouTotal: Int
    public var runningTotal: Int
    public var waitingTotal: Int
    public var failedTotal: Int

    public init(sessions: [SessionSummary], now: Date = Date()) {
        let unarchived = sessions.filter { $0.status != .archived }
        let needs = unarchived.filter { $0.status == .needsInput }
        let failed = unarchived.filter { $0.status == .failed }
        let running = unarchived.filter { $0.status == .running }
        let waiting = unarchived.filter { $0.status == .waiting }
        needsYouTotal = needs.count
        failedTotal = failed.count
        runningTotal = running.count
        waitingTotal = waiting.count
        needsYou = Array((SessionOrdering.sorted(needs) + SessionOrdering.sorted(failed)).prefix(Self.listLimit)).map { DrivingCard($0, now: now) }
        working = Array((SessionOrdering.sorted(running) + SessionOrdering.sorted(waiting)).prefix(Self.listLimit)).map { DrivingCard($0, now: now) }
    }

    public static let empty = DrivingBoard(sessions: [])

    public var needsNothing: Bool { needsYouTotal == 0 && failedTotal == 0 }

    /// "2 need you · 3 running": the home tile's second line.
    public var summaryLine: String {
        var parts: [String] = []
        if needsYouTotal + failedTotal > 0 { parts.append("\(needsYouTotal + failedTotal) need you") }
        if runningTotal > 0 { parts.append("\(runningTotal) running") }
        if waitingTotal > 0 { parts.append("\(waitingTotal) waiting") }
        return parts.isEmpty ? "Nothing needs you" : parts.joined(separator: " · ")
    }

    public func card(_ id: Int) -> DrivingCard? {
        (needsYou + working).first { $0.id == id }
    }
}

/// One session as the car presents it: a row's two lines, and the opening line Live Mode is
/// given when the driver taps it.
public struct DrivingCard: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case needsInput, failed, running, waiting
    }

    public let session: SessionSummary
    public let kind: Kind
    /// What it needs, or what it is doing, in one line: the status summary's first sentence
    /// as plain words, or a fallback for the status.
    public let headline: String
    /// "Needs input · 12m".
    public let statusLine: String

    public var id: Int { session.id }
    public var title: String { session.displayTitle }

    public init(_ session: SessionSummary, now: Date = Date()) {
        self.session = session
        let kind: Kind = switch session.status {
        case .needsInput: .needsInput
        case .failed: .failed
        case .waiting: .waiting
        default: .running
        }
        self.kind = kind
        let summary = DrivingWords.firstSentence(DrivingWords.plain(session.boardRow?.statusSummary?.summary ?? ""))
        headline = summary.isEmpty ? Self.fallbackHeadline(kind) : summary
        var status = session.status.label
        if let at = session.updatedAt { status += " · \(Format.age(at, now: now))" }
        statusLine = status
    }

    static func fallbackHeadline(_ kind: Kind) -> String {
        switch kind {
        case .needsInput: return "Waiting for your reply."
        case .failed: return "Failed. Restart it, or talk it through."
        case .running: return "Working."
        case .waiting: return "Waiting to start."
        }
    }

    /// The line the car gives Live Mode when the driver taps this session's row: the session,
    /// in words the model can find it by, and what to do first. The row is a way into the one
    /// conversation, not a conversation of its own.
    public var opening: String {
        "Let's talk about session \(id), \"\(title)\". It is \(session.status.label.lowercased()). " +
            "Tell me where it stands in a sentence, then ask me what I want to do."
    }

    /// The row's second line: what it needs, or for a session at work with nothing to say
    /// yet, how long it has been at it.
    public var detail: String {
        switch kind {
        case .needsInput, .failed: return headline
        case .running, .waiting: return headline == Self.fallbackHeadline(kind) ? statusLine : headline
        }
    }
}

/// Markdown into words a list row holds: a status summary is markdown with links and emphasis,
/// and a CarPlay row wants neither.
public enum DrivingWords {
    public static func plain(_ markdown: String) -> String {
        var text = markdown
        // [text](url) → text; a bare <url> → nothing.
        text = replace(text, #"\[([^\]]*)\]\([^)]*\)"#, with: "$1")
        text = replace(text, #"<https?://[^>]*>"#, with: "")
        // Headings, list markers and quote marks at a line's start.
        text = replace(text, #"(?m)^\s{0,3}(#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s?)"#, with: "")
        // Emphasis and code marks.
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        text = replace(text, #"(?<!\w)[*_](?=\S)([^*_]+?)(?<=\S)[*_](?!\w)"#, with: "$1")
        text = text.replacingOccurrences(of: "`", with: "")
        // Whitespace, line breaks included, to single spaces.
        text = replace(text, #"\s+"#, with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first sentence, capped: a row has one line.
    public static func firstSentence(_ text: String, limit: Int = 140) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var sentence = trimmed
        if let end = sentenceEnd(in: trimmed) { sentence = String(trimmed[..<end]) }
        if sentence.count > limit {
            let cut = sentence.prefix(limit)
            let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
            sentence = String(atWord).trimmingCharacters(in: .punctuationCharacters) + "…"
        }
        return sentence
    }

    /// The index just past the first sentence's end mark: a `.`, `!` or `?` followed by a
    /// space or the end, not one inside "v1.2" or "PR #1261.5".
    private static func sentenceEnd(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if ".!?".contains(character) {
                let next = text.index(after: index)
                if next == text.endIndex || text[next].isWhitespace { return next }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func replace(_ text: String, _ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
