import CarPlay
import Foundation
import ZimmerKit
import os

/// Zimmer in the car, as a CarPlay **voice-based conversational app**
/// (`com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+).
///
/// Voice first, as that category requires: on connect it reads out how many sessions need
/// the driver and the first of them, and listens for an answer — yes, a reply, archive,
/// next, stop (`DrivingFlow`, which holds every rule and is tested on Linux). Archive and
/// replies are confirmed out loud first; "yes" sends the approval at once. The screen underneath is a short
/// list of the sessions that need input, each row an action sheet (Approve, Reply by
/// voice, Archive) for a driver who would rather tap; a Talk button restarts the
/// conversation. Every template used — list, action sheet, voice control — is one the
/// category allows, and the stack never goes deeper than three.
///
/// CarPlay connects the scene declared in Info.plist only in a build that signs in the
/// entitlement: `App/Zimmer/CarPlay.entitlements`, which `ios/bin/testflight` signs into every
/// TestFlight build. A simulator build carries none; see ios/README.md, "CarPlay".
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var sessions: [SessionSummary] = []
    /// Why the last refresh failed, spoken instead of "nothing needs you" — a driver
    /// cannot be expected to read the screen.
    private var refreshFailure: String?
    private var summaries: [Int: String] = [:]
    private var refreshTask: Task<Void, Never>?
    private var conversation: Task<Void, Never>?
    private let voice = VoiceIO()
    /// Live Mode, voice on: start or resume a conversation from the list (CarPlayLive).
    private let live = CarPlayLive()
    /// The root list, kept so the Live Mode section can be redrawn in place as a call starts
    /// and ends without resetting the template stack.
    private var listTemplate: CPListTemplate?
    private var sessionsSection = CPListSection(items: [])
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "carplay")

    private enum VoiceState {
        static let listening = "listening"
        static let speaking = "speaking"
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        live.interfaceController = interfaceController
        live.onChange = { [weak self] in self?.redrawLiveSection() }
        let loading = CPListTemplate(title: "Zimmer", sections: [])
        loading.emptyViewSubtitleVariants = ["Checking your sessions…"]
        interfaceController.setRootTemplate(loading, animated: false, completion: nil)
        refreshTask = Task {
            await refresh()
            // Voice first, as the category requires. The scene only ever connects on
            // iOS 26.4+, where the voice-based conversational entitlement exists. A Live Mode voice
            // call already running is the conversation: it carries on, and the screen offers
            // Back to the call.
            guard !LiveCall.shared.isActive else { return }
            startConversation()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        refreshTask?.cancel()
        conversation?.cancel()
        voice.end()
        self.interfaceController = nil
    }

    // MARK: - The list

    private func refresh() async {
        let connection = AppEnvironment.shared.connection
        guard await connection.auth.isSignedIn else {
            refreshFailure = "Sign in to Zimmer on your phone first."
            showMessage(refreshFailure!)
            return
        }
        await live.refresh()
        do {
            sessions = try await connection.api.sessions(.needsInput)
            summaries = [:]
            for session in sessions.prefix(DrivingFlow.limit) {
                if let summary = try? await connection.api.session(session.id).statusSummary?.summary {
                    // The summary is markdown; a list row and a voice read its words, so a
                    // link is its text without the brackets and the URL.
                    summaries[session.id] = String(MarkdownInline.attributed(summary).characters)
                }
            }
            refreshFailure = nil
            showList()
        } catch {
            log.error("refresh failed: \(String(describing: error), privacy: .public)")
            refreshFailure = (error as? ZimmerError)?.userMessage ?? "Couldn't reach Zimmer."
            showMessage(refreshFailure!)
        }
    }

    private func showList() {
        let items = sessions.prefix(DrivingFlow.limit).map { session -> CPListItem in
            let item = CPListItem(text: session.displayTitle, detailText: summaries[session.id] ?? session.status.label)
            item.handler = { [weak self] _, completion in
                self?.showActions(for: session)
                completion()
            }
            return item
        }
        // The Live Mode section is always there, so the list is never empty and its empty view
        // would never show: an empty queue says so in a row instead.
        let rows = items.isEmpty ? [CPListItem(text: "Nothing needs you right now.", detailText: nil)] : items
        sessionsSection = CPListSection(items: rows)
        let template = CPListTemplate(title: "Needs you", sections: [sessionsSection, live.section()])
        listTemplate = template
        template.trailingNavigationBarButtons = [
            CPBarButton(title: "Talk") { [weak self] _ in self?.startConversation() },
        ]
        interfaceController?.setRootTemplate(template, animated: true, completion: nil)
    }

    /// A call started or ended: redraw the Live Mode section where it is.
    private func redrawLiveSection() {
        listTemplate?.updateSections([sessionsSection, live.section()])
    }

    private func showMessage(_ text: String) {
        let template = CPListTemplate(title: "Zimmer", sections: [])
        template.emptyViewSubtitleVariants = [text]
        interfaceController?.setRootTemplate(template, animated: true, completion: nil)
    }

    private func showActions(for session: SessionSummary) {
        var actions: [CPAlertAction] = [
            CPAlertAction(title: "Approve", style: .default) { [weak self] _ in
                self?.dismissThen {
                    if await self?.perform(.followUp(sessionID: session.id, text: VoiceCommand.approvalText), spoken: false) == true {
                        await self?.refresh()
                    }
                }
            },
        ]
        // Only where the phone can recognise speech on its own: see VoiceIO.
        if VoiceIO.canListen {
            actions.append(CPAlertAction(title: "Reply by voice", style: .default) { [weak self] _ in
                self?.dismissThen { self?.startConversation(focusing: session.id) }
            })
        }
        actions.append(CPAlertAction(title: "Archive", style: .destructive) { [weak self] _ in
            self?.dismissThen {
                if await self?.perform(.archive(sessionID: session.id), spoken: false) == true {
                    await self?.refresh()
                }
            }
        })
        actions.append(CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        })
        let sheet = CPActionSheetTemplate(title: session.displayTitle, message: summaries[session.id], actions: actions)
        interfaceController?.presentTemplate(sheet, animated: true, completion: nil)
    }

    private func dismissThen(_ next: @escaping @MainActor () async -> Void) {
        interfaceController?.dismissTemplate(animated: true) { _, _ in
            Task { @MainActor in await next() }
        }
    }

    // MARK: - The conversation

    private func startConversation(focusing sessionID: Int? = nil) {
        // One conversation with the car at a time: a voice call is it until hung up.
        guard !LiveCall.shared.isActive else { return }
        conversation?.cancel()
        var ordered = sessions
        if let sessionID, let index = ordered.firstIndex(where: { $0.id == sessionID }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        var flow = DrivingFlow(sessions: ordered, summaries: summaries)
        let template = CPVoiceControlTemplate(voiceControlStates: [
            CPVoiceControlState(identifier: VoiceState.listening, titleVariants: ["Listening…"], image: nil, repeats: true),
            CPVoiceControlState(identifier: VoiceState.speaking, titleVariants: ["Zimmer"], image: nil, repeats: false),
        ])
        interfaceController?.presentTemplate(template, animated: true, completion: nil)

        conversation = Task { [weak self] in
            guard let self else { return }
            self.voice.begin()
            defer {
                self.voice.end()
                // Only its own template: a newer conversation's must survive this one ending.
                if self.interfaceController?.presentedTemplate === template {
                    self.interfaceController?.dismissTemplate(animated: true, completion: nil)
                }
            }
            if let failure = self.refreshFailure {
                await self.voice.speak(failure)
                return
            }
            // Say it before asking the driver to speak, not after showing "Listening…".
            guard VoiceIO.canListen else {
                let waiting = flow.queue.count
                let count = waiting == 0 ? "Nothing needs you right now." : waiting == 1 ? "One session needs you." : "\(waiting) sessions need you."
                await self.voice.speak("\(count) This iPhone can't recognise speech on its own, so use Approve or Archive on the screen.")
                return
            }
            var effects = flow.opening()
            var misses = 0
            while !Task.isCancelled {
                var acted = false
                var skipNextLine = false
                for effect in effects {
                    guard !Task.isCancelled else { return }
                    switch effect {
                    case .end:
                        if acted { await self.refresh() }
                        return
                    case let .speak(line):
                        // The line after an action announces it; a failed action already
                        // said why, and must not then be called done.
                        if skipNextLine { skipNextLine = false; continue }
                        template.activateVoiceControlState(withIdentifier: VoiceState.speaking)
                        await self.voice.speak(line)
                    case .followUp, .archive:
                        if await self.perform(effect, spoken: true) { acted = true } else { skipNextLine = true }
                    }
                }
                // Refresh after the confirmation is spoken, not before it: a driver should
                // not sit through several requests' silence.
                if acted { await self.refresh() }
                template.activateVoiceControlState(withIdentifier: VoiceState.listening)
                guard let heard = await self.voice.listen(), let command = VoiceCommand(heard) else {
                    misses += 1
                    if misses >= 2 { await self.voice.speak("I'll leave it there."); return }
                    effects = [.speak("Sorry, I didn't catch that.")]
                    continue
                }
                misses = 0
                effects = flow.handle(command)
            }
        }
    }

    /// The effects that touch Zimmer; true when they worked. A failure is spoken here.
    /// Speech and the end of the conversation are handled by the loop above.
    /// `spoken`: the driver said it, so the session is told it was dictated in the car;
    /// a tapped button is still the car, but says nothing about how.
    private func perform(_ effect: DrivingFlow.Effect, spoken: Bool) async -> Bool {
        let api = AppEnvironment.shared.connection.api
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let source = ClientSource.app(version: version).onCarPlay(modality: spoken ? .voiceDictation : nil)
        do {
            switch effect {
            case let .followUp(sessionID, text):
                _ = try await api.followUp(sessionID, prompt: text, from: source)
            case let .archive(sessionID):
                _ = try await api.archive(sessionID)
            case .speak, .end:
                return true
            }
            return true
        } catch {
            log.error("action failed: \(String(describing: error), privacy: .public)")
            await voice.speak((error as? ZimmerError)?.userMessage ?? "That didn't work.")
            return false
        }
    }
}
