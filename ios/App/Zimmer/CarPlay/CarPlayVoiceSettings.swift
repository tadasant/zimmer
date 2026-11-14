import CarPlay
import Foundation
import ZimmerKit
import os

/// The voice settings panel: the break-glass for a call that has stopped working, whose driver
/// therefore cannot ask it to fix that. The rules are `CarVoiceSettings`; this draws them.
///
/// One list template, pushed, and that is the only change it ever makes: a row's choices are the
/// same list with its sections replaced, so going in and out of them is no template change for
/// CarPlay to refuse, and nothing here is deeper than the one screen. Every row is a name and a
/// value, a choice is one tap, and the way back is at the top of the list. CarPlay's own Back
/// knows only the one template, so from a row's choices it closes the panel.
///
/// Opened from the call screen's gear its way out is *Back to the call*, which calls again; opened
/// from the home's Voice settings tile there is no call, and the way out is *Done*.
@MainActor
final class CarPlayVoiceSettings {
    let template = CPListTemplate(title: "Voice settings", sections: [])
    /// The gear opened it, on a call that comes back when it closes. False from the home's tile.
    let fromCall: Bool
    /// Back to the call, or to the home.
    var onClose: (() -> Void)?
    /// A write landed, naming what it changed.
    var onWritten: ((String) -> Void)? {
        didSet { model.onWritten = onWritten }
    }

    private let model: CarVoiceSettingsModel
    /// A row's handler ran and the list was drawn again: with CarPlay's own log, these say how far
    /// a tap that changed nothing got.
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "carplay")

    init(api: any LiveAPI, fromCall: Bool) {
        self.fromCall = fromCall
        model = CarVoiceSettingsModel(api: api)
        model.onChange = { [weak self] in self?.draw() }
        draw()
    }

    func load() async {
        await model.load()
    }

    /// Every write the driver made has been answered.
    func settled() async {
        await model.settled()
    }

    var isSaving: Bool { model.saving }
    var writeFailed: Bool { model.writeFailed }

    private func draw() {
        log.notice("voice settings drawn: \(String(describing: self.model.page), privacy: .public), loaded \(self.model.settings != nil, privacy: .public)")
        var top: [CPListItem] = []
        if let problem = model.problem {
            top.append(item(problem, detail: model.settings == nil ? "Tap to try again" : nil) { [weak self] in
                guard let self, self.model.settings == nil else { return }
                Task { await self.model.load() }
            })
        }
        if let row = model.openRow {
            top.append(item("Back to settings", detail: model.saving ? "Saving…" : row.title) { [weak self] in self?.model.back() })
            let choices = row.choices.map { choice in
                item(choice.title, detail: choice.isCurrent ? "In use" : choice.note) { [weak self] in self?.model.choose(choice) }
            }
            template.updateSections([CPListSection(items: top + choices)])
            return
        }
        top.insert(item(fromCall ? "Back to the call" : "Done", detail: model.saving ? "Saving…" : nil) { [weak self] in self?.onClose?() }, at: 0)
        guard let settings = model.settings else {
            if model.problem == nil { top.append(item("Loading…")) }
            template.updateSections([CPListSection(items: top)])
            return
        }
        // Reset comes straight after the way back: the panel is a break-glass, and neither of the
        // two things it is for should be down a list a driver has to scroll.
        let reset = item("Reset to defaults", detail: resetDetail(settings)) { [weak self] in self?.model.reset() }
        reset.isEnabled = settings.canReset
        let rows = settings.rows.map { row in
            let listItem = item(row.title, detail: row.detail) { [weak self] in self?.model.open(row) }
            listItem.accessoryType = .disclosureIndicator
            return listItem
        }
        template.updateSections([CPListSection(items: top + [reset] + rows)])
    }

    private func resetDetail(_ settings: CarVoiceSettings) -> String {
        guard settings.canReset else { return "Already on the defaults" }
        return fromCall ? "Takes effect when the call comes back" : "Takes effect on the next call"
    }

    private func item(_ text: String, detail: String? = nil, tapped: (@MainActor @Sendable () -> Void)? = nil) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail)
        item.handler = Self.handler(text, log: log, tapped: tapped)
        return item
    }

    /// Static, so the closure CarPlay is given belongs to no actor: a row can be tapped from any
    /// thread (`CarPlayTap`).
    private nonisolated static func handler(_ text: String, log: Logger, tapped: (@MainActor @Sendable () -> Void)?) -> @Sendable (any CPSelectableListItem, @escaping () -> Void) -> Void {
        { _, done in
            nonisolated(unsafe) let done = done
            CarPlayTap.run(arrived: { CarPlayImages.arrived("row", onMain: $0) }) {
                log.notice("voice settings row handler: \(text, privacy: .public)")
                tapped?()
                done()
            }
        }
    }
}
