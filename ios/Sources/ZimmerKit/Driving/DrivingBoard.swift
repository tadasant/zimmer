import Foundation

/// What the car shows and says, worked out from the board: the sessions that need the driver,
/// the ones at work, and the words for each row, card and briefing. It touches no network,
/// audio or CarPlay API, so every rule is tested on Linux; the CarPlay scene renders it.
///
/// Two lists, because a driver has two questions: *does anything need me?* and *what is going
/// on?* Each is capped at what a car is guaranteed to show (`listLimit`) and ordered as the
/// board's Needs input view is: the session the person touched last comes first.
public struct DrivingBoard: Hashable, Sendable {
    /// Some cars cap a list at 12 rows; Apple's guide says to be ready for that.
    public static let listLimit = 12

    /// Needs input and failed: each a decision the driver can take with one or two taps.
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

/// One session as the car presents it: a row's two lines, a card's labels and buttons, and
/// the sentence the car says for it.
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
    /// "#1261 · open · CI green", for the newest pull request.
    public let pullRequestLine: String?

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
        pullRequestLine = session.pullRequests.last.map { pr in
            var line = pr.label
            if let state = pr.state { line += " · \(state)" }
            if let ci = pr.ci { line += ci == "pass" ? " · CI green" : " · CI \(ci)" }
            return line
        }
    }

    static func fallbackHeadline(_ kind: Kind) -> String {
        switch kind {
        case .needsInput: return "Waiting for your reply."
        case .failed: return "Failed. Restart it, or talk it through."
        case .running: return "Working."
        case .waiting: return "Waiting to start."
        }
    }

    /// The card's footer buttons, the obvious one first. A green PR's decision is the merge, so
    /// that leads; otherwise the common answer, go ahead, does.
    public var actions: [DrivingAction] {
        switch kind {
        case .needsInput:
            if let pr = session.mergeablePullRequest { return [.merge(pr), .talkAboutIt] }
            return [.goAhead, .talkAboutIt]
        case .failed:
            return [.restart, .talkAboutIt]
        case .running, .waiting:
            return [.talkAboutIt, .readAloud]
        }
    }

    /// Behind the card's More button: the rest, with the destructive one last.
    public var more: [DrivingAction] {
        switch kind {
        case .needsInput:
            return (session.mergeablePullRequest != nil ? [.goAhead] : []) + [.readAloud, .archive]
        case .failed:
            return [.readAloud, .archive]
        case .running, .waiting:
            return []
        }
    }

    /// What the car says when the card opens, and in the briefing: the title, then the line.
    public var spoken: String {
        DrivingWords.sentence(title) + " " + DrivingWords.sentence(headline)
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

/// What a card's button does. Each names its words, whether it is confirmed first, and what
/// the car says when it has worked. Merge and archive confirm: a merge ships, and an archive
/// takes a session off the board. Go ahead and restart act at once: a tap is deliberate, and
/// both only tell the agent to carry on. Trash is not here at all: it is for a desk.
public enum DrivingAction: Hashable, Sendable {
    /// Send *Yes, go ahead.*, the usual answer to a session waiting on a person.
    case goAhead
    /// The person's sign-off on the session's green PR (`authorize_merge`).
    case merge(PullRequestLink)
    /// Start, or come back to, Live Mode with this session as the subject.
    case talkAboutIt
    case restart
    case archive
    /// Say the card again.
    case readAloud

    public static let goAheadText = "Yes, go ahead."

    public var title: String {
        switch self {
        case .goAhead: return "Go ahead"
        case let .merge(pr): return "Merge \(pr.label)"
        case .talkAboutIt: return "Talk about it"
        case .restart: return "Restart"
        case .archive: return "Archive"
        case .readAloud: return "Read aloud"
        }
    }

    public var isDestructive: Bool { self == .archive }

    /// The question asked before acting, or nil to act on the tap.
    public func confirmation(for card: DrivingCard) -> String? {
        switch self {
        case let .merge(pr): return "Merge \(pr.label)? The session merges it and archives itself."
        case .archive: return "Archive \(card.title)?"
        default: return nil
        }
    }

    /// Spoken once the action has worked. nil for the ones that do not touch Zimmer.
    public var spokenDone: String? {
        switch self {
        case .goAhead: return "Told it to go ahead."
        case .merge: return "Merge authorized."
        case .restart: return "Restarting."
        case .archive: return "Archived."
        case .talkAboutIt, .readAloud: return nil
        }
    }

    /// The line the car gives Live Mode for Talk about it: the session, in words the model can
    /// find it by, and what to do first.
    public static func opening(for card: DrivingCard) -> String {
        "Let's talk about session \(card.id), \"\(card.title)\". It is \(card.session.status.label.lowercased()). " +
            "Tell me where it stands in a sentence, then ask me what I want to do."
    }
}

/// The briefing the driver asks for with the Briefing tile: what needs them, what is running.
/// The car never says it unasked.
public enum Briefing {
    /// Up to this many sessions are read in full; the rest are counted.
    public static let spokenLimit = 3

    public static func text(for board: DrivingBoard) -> String {
        var lines: [String] = []
        // The totals, not the capped list: twenty sessions are twenty, however many a car shows.
        let total = board.needsYouTotal + board.failedTotal
        switch total {
        case 0: lines.append("Nothing needs you.")
        case 1: lines.append("One session needs you.")
        default: lines.append("\(total) sessions need you.")
        }
        for (index, card) in board.needsYou.prefix(spokenLimit).enumerated() {
            let ordinal = total == 1 ? "" : "\(Self.ordinal(index + 1)): "
            lines.append(ordinal + card.spoken)
        }
        if total > spokenLimit {
            lines.append("And \(total - spokenLimit) more.")
        }
        var working: [String] = []
        if board.runningTotal > 0 { working.append(board.runningTotal == 1 ? "One running" : "\(board.runningTotal) running") }
        if board.waitingTotal > 0 { working.append(board.waitingTotal == 1 ? "one waiting" : "\(board.waitingTotal) waiting") }
        if !working.isEmpty { lines.append(working.joined(separator: ", ") + ".") }
        return lines.joined(separator: " ")
    }

    /// Spoken when the board could not be read: never "nothing needs you" for a network error.
    public static func failure(_ reason: String) -> String {
        "I couldn't check your sessions. \(DrivingWords.sentence(reason))"
    }

    static func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "First"
        case 2: return "Second"
        case 3: return "Third"
        default: return "Number \(n)"
        }
    }
}

/// Markdown into words a list row holds and a voice reads: a status summary is markdown with
/// links and emphasis, and neither a CarPlay row nor a speech synthesizer wants the marks.
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

    /// The first sentence, capped: a row has one line and a voice has a breath.
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

    /// `text` ending in a full stop, so sentences read with a pause between them.
    public static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?…".contains(last) ? trimmed : trimmed + "."
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
