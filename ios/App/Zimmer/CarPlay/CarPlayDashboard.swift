import CarPlay
import Foundation
import ZimmerKit

/// The car's screens when no call is up: a tab bar with three tabs, each one question.
///
/// - **Zimmer**, a grid of three tiles: *Talk to Zimmer* (Live Mode, the one conversation), then
///   *Needs you* and *Running* with their counts. A grid's tiles are the largest targets CarPlay
///   draws. The Talk tile is also where the car says Live Mode is not there: *Live Mode
///   unavailable, retrying…*, never a voice.
/// - **Needs you**, a list of the sessions waiting on a decision — needs input, then failed —
///   with a badge on the tab while there are any. A row is one line of what it needs.
/// - **Running**, a list of the sessions at work, with what each is doing.
///
/// A row is a way into the one conversation, not a screen of its own: tapping it starts (or
/// carries on) the Live Mode call with a line that names the session, and the conversation
/// takes it from there — merging, answering, restarting, archiving, all by voice, through Live
/// Mode's tools. The car has no per-session buttons and no other voice.
///
/// Depth: the tab bar is the root (1) and nothing is pushed on it. The only modal is the call's
/// voice control template, which `CarPlayLive` presents.
@MainActor
final class CarPlayDashboard {
    let tabBar: CPTabBarTemplate
    var onTalk: (() -> Void)?
    /// A row was tapped: talk about this session, in the one conversation.
    var onTalkAbout: ((DrivingCard) -> Void)?

    private let home: CPGridTemplate
    private let needsYou: CPListTemplate
    private let working: CPListTemplate
    private var board = DrivingBoard.empty
    private var failure: String?

    var talkTile = LiveTalkTile.ready {
        didSet { if talkTile != oldValue { drawHome() } }
    }

    init() {
        home = CPGridTemplate(title: "Zimmer", gridButtons: [])
        home.tabTitle = "Zimmer"
        home.tabImage = CarPlayImages.tab("waveform")
        needsYou = CPListTemplate(title: "Needs you", sections: [])
        needsYou.tabTitle = "Needs you"
        needsYou.tabImage = CarPlayImages.tab("exclamationmark.bubble.fill")
        working = CPListTemplate(title: "Running", sections: [])
        working.tabTitle = "Running"
        working.tabImage = CarPlayImages.tab("play.circle.fill")
        tabBar = CPTabBarTemplate(templates: [home, needsYou, working])
        drawHome()
        drawLists()
    }

    func show(_ board: DrivingBoard) {
        self.board = board
        failure = nil
        drawHome()
        drawLists()
    }

    /// The board could not be read: the lists say why instead of "nothing".
    func show(failure: String) {
        self.failure = failure
        board = .empty
        drawHome()
        drawLists()
    }

    var needsYouCount: Int { board.needsYouTotal + board.failedTotal }

    // MARK: - Home

    private func drawHome() {
        let talk = CPGridButton(titleVariants: talkTile.titleVariants, image: CarPlayImages.tile(talkTile.symbol)) { [weak self] _ in
            self?.onTalk?()
        }
        let needs = needsYouCount
        let needsTile = CPGridButton(
            titleVariants: needs > 0 ? ["Needs you · \(needs)", "Needs you"] : ["Needs you"],
            image: CarPlayImages.tile("exclamationmark.bubble.fill")
        ) { [weak self] _ in self?.select(self?.needsYou) }
        let running = board.runningTotal + board.waitingTotal
        let runningTile = CPGridButton(
            titleVariants: running > 0 ? ["Running · \(running)", "Running"] : ["Running"],
            image: CarPlayImages.tile("play.circle.fill")
        ) { [weak self] _ in self?.select(self?.working) }
        home.updateGridButtons([talk, needsTile, runningTile])
    }

    private func select(_ template: CPTemplate?) {
        guard let template, let index = tabBar.templates.firstIndex(where: { $0 === template }) else { return }
        tabBar.selectTemplate(at: index)
    }

    // MARK: - Lists

    private func drawLists() {
        needsYou.updateSections(sections(board.needsYou))
        needsYou.emptyViewTitleVariants = [failure == nil ? "Nothing needs you" : "Couldn't check"]
        needsYou.emptyViewSubtitleVariants = [failure ?? "Every session is either working or done."]
        let badge = !board.needsYou.isEmpty
        working.updateSections(sections(board.working))
        working.emptyViewTitleVariants = [failure == nil ? "Nothing running" : "Couldn't check"]
        working.emptyViewSubtitleVariants = [failure ?? "Talk to Zimmer to start something."]
        // The tab bar is told again only when the badge turns on or off: telling it every
        // minute could put a driver reading a list back on the first tab.
        if badge != needsYou.showsTabBadge {
            needsYou.showsTabBadge = badge
            tabBar.updateTemplates([home, needsYou, working])
        }
    }

    private func sections(_ cards: [DrivingCard]) -> [CPListSection] {
        let items = cards.map { card -> CPListItem in
            let item = CPListItem(text: card.title, detailText: card.detail, image: CarPlayImages.row(Self.symbol(for: card)))
            item.handler = { [weak self] _, completion in
                self?.onTalkAbout?(card)
                completion()
            }
            return item
        }
        return items.isEmpty ? [] : [CPListSection(items: items)]
    }

    private static func symbol(for card: DrivingCard) -> String {
        switch card.kind {
        case .needsInput: return card.session.mergeablePullRequest != nil ? "arrow.triangle.merge" : "questionmark.bubble.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .running: return "play.circle.fill"
        case .waiting: return "clock.fill"
        }
    }
}
