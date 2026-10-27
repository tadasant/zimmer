import CarPlay
import Foundation
import ZimmerKit

/// The car's screens when no call is up: a tab bar with three tabs, each one question.
///
/// - **Zimmer**, a grid of four tiles: *Talk to Zimmer* (the default: Live Mode), *Briefing*
///   (the car says what needs you, only when asked), *Needs you* and *Running* with their
///   counts. A grid's tiles are the largest targets CarPlay draws.
/// - **Needs you**, a list of the sessions waiting on a decision — needs input, then failed —
///   with a badge on the tab while there are any. A row is one line of what it needs.
/// - **Running**, a list of the sessions at work, with what each is doing.
///
/// A row opens a card (an information template): the headline in large type, the status, the
/// PR, and up to three buttons — the decision first (*Merge*, *Go ahead* or *Restart*), *Talk
/// about it*, and *More* for the rest. Merge and Archive ask first; Trash is not offered at all.
/// Opening a card reads it aloud, so the driver need not look.
///
/// Depth: the tab bar is the root (1), a card is pushed on it (2), and an alert or a sheet is
/// presented over that. A voice-based conversational app may go three deep; this stops at two.
@MainActor
final class CarPlayDashboard {
    let tabBar: CPTabBarTemplate
    weak var interfaceController: CPInterfaceController?
    var onTalk: (() -> Void)?
    var onBriefing: (() -> Void)?
    var onAction: ((DrivingAction, DrivingCard) -> Void)?
    /// A card was opened: say it.
    var onOpen: ((DrivingCard) -> Void)?

    private let home: CPGridTemplate
    private let needsYou: CPListTemplate
    private let working: CPListTemplate
    private var board = DrivingBoard.empty
    private var failure: String?

    var callIsActive = false {
        didSet { drawHome() }
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
        let talk = CPGridButton(
            titleVariants: callIsActive ? ["Back to the call", "Call"] : ["Talk to Zimmer", "Talk"],
            image: CarPlayImages.tile(callIsActive ? "waveform" : "mic.fill")
        ) { [weak self] _ in self?.onTalk?() }
        let briefing = CPGridButton(titleVariants: ["Briefing"], image: CarPlayImages.tile("speaker.wave.2.fill")) { [weak self] _ in
            self?.onBriefing?()
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
        home.updateGridButtons([talk, briefing, needsTile, runningTile])
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
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.open(card)
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

    // MARK: - A card

    func open(_ card: DrivingCard) {
        guard let interfaceController else { return }
        // One card at a time: a row tapped from a card's tab replaces the card.
        if interfaceController.topTemplate as? CPInformationTemplate != nil {
            interfaceController.popTemplate(animated: false, completion: nil)
        }
        interfaceController.pushTemplate(cardTemplate(card), animated: true, completion: nil)
        onOpen?(card)
    }

    /// The card for `id` is on top: take it down (the session left the list).
    func close(card id: Int) {
        guard let interfaceController, let top = interfaceController.topTemplate as? CPInformationTemplate, top.userInfo as? Int == id else { return }
        interfaceController.popTemplate(animated: true, completion: nil)
    }

    private func cardTemplate(_ card: DrivingCard) -> CPInformationTemplate {
        var items = [
            CPInformationItem(title: card.kind == .needsInput || card.kind == .failed ? "Needs you" : "Now", detail: card.headline),
            CPInformationItem(title: "Status", detail: card.statusLine),
        ]
        if let pullRequest = card.pullRequestLine {
            items.append(CPInformationItem(title: "Pull request", detail: pullRequest))
        }
        var actions = card.actions.enumerated().map { index, action in
            CPTextButton(title: action.title, textStyle: index == 0 ? .confirm : .normal) { [weak self] _ in
                self?.onAction?(action, card)
            }
        }
        if !card.more.isEmpty {
            actions.append(CPTextButton(title: "More", textStyle: .normal) { [weak self] _ in self?.showMore(card) })
        }
        let template = CPInformationTemplate(title: card.title, layout: .leading, items: items, actions: actions)
        template.userInfo = card.id
        template.trailingNavigationBarButtons = [
            CPBarButton(image: CarPlayImages.bar("speaker.wave.2")) { [weak self] _ in self?.onAction?(.readAloud, card) },
        ]
        return template
    }

    private func showMore(_ card: DrivingCard) {
        var actions = card.more.map { action in
            CPAlertAction(title: action.title, style: action.isDestructive ? .destructive : .default) { [weak self] _ in
                self?.dismissThen { self?.onAction?(action, card) }
            }
        }
        actions.append(CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        })
        let sheet = CPActionSheetTemplate(title: card.title, message: card.headline, actions: actions)
        interfaceController?.presentTemplate(sheet, animated: true, completion: nil)
    }

    // MARK: - Alerts

    /// A question before an action that ships or files something away: one button to do it,
    /// one to leave it.
    func confirm(_ question: String, action: DrivingAction, then proceed: @escaping @MainActor () -> Void) {
        let alert = CPAlertTemplate(titleVariants: [question], actions: [
            CPAlertAction(title: action.title, style: action.isDestructive ? .destructive : .default) { [weak self] _ in
                self?.dismissThen(proceed)
            },
            CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            },
        ])
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }

    /// Something went wrong, in one line, with one button.
    func alert(_ message: String) {
        guard let interfaceController, interfaceController.presentedTemplate == nil else { return }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [
            CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
                self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            },
        ])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    private func dismissThen(_ next: @escaping @MainActor () -> Void) {
        interfaceController?.dismissTemplate(animated: true) { _, _ in
            Task { @MainActor in next() }
        }
    }
}

/// The car speaking the briefing the driver asked for, under the voice control template, as the
/// category asks of any voice in use. Two buttons while it speaks: into Live Mode, or dismiss.
/// It leaves on its own a moment after the words end, so a driver who does nothing is back at
/// the dashboard. Never shown unasked: the car says nothing until something is tapped.
@MainActor
final class CarPlayAnnouncement {
    weak var interfaceController: CPInterfaceController?
    /// The driver chose to talk, with the opening line the announcement was about, if any.
    var onTalk: ((String?) -> Void)?

    private let speech: CarPlaySpeech
    private var template: CPVoiceControlTemplate?
    private static let state = "speaking"
    /// How long the buttons stay after the words end.
    private static let linger: Duration = .seconds(4)

    init(speech: CarPlaySpeech) {
        self.speech = speech
    }

    var isShowing: Bool { template != nil }

    /// Says `text` under a screen titled `titleVariants`, offering `talkTitle` (which starts
    /// Live Mode with `opening`) and Dismiss. With a modal already up, or a call running, it
    /// only speaks — or, in a call, says nothing.
    func announce(_ text: String, titleVariants: [String], talkTitle: String, opening: String?) async {
        guard let interfaceController, interfaceController.presentedTemplate == nil, !LiveCall.shared.isActive else {
            await speech.speak(text)
            return
        }
        let state = CPVoiceControlState(identifier: Self.state, titleVariants: titleVariants, image: CarPlayImages.announcement, repeats: false)
        if #available(iOS 26.4, *) {
            let buttons: [CPButton] = [
                CPTextButton(title: talkTitle, textStyle: .confirm) { [weak self] _ in
                    self?.speech.stop()
                    self?.onTalk?(opening)
                },
                CPTextButton(title: "Dismiss", textStyle: .cancel) { [weak self] _ in
                    self?.speech.stop()
                    self?.dismiss()
                },
            ]
            state.actionButtons = buttons
        }
        let template = CPVoiceControlTemplate(voiceControlStates: [state])
        self.template = template
        interfaceController.presentTemplate(template, animated: true, completion: nil)
        template.activateVoiceControlState(withIdentifier: Self.state)
        await speech.speak(text)
        guard self.template === template else { return }
        try? await Task.sleep(for: Self.linger)
        guard self.template === template else { return }
        dismiss()
    }

    func dismiss() {
        guard let template else { return }
        self.template = nil
        if let interfaceController, interfaceController.presentedTemplate === template {
            interfaceController.dismissTemplate(animated: true, completion: nil)
        }
    }
}
