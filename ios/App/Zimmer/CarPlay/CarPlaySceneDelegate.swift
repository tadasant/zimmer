import CarPlay
import Foundation
import ZimmerKit
import os

/// Zimmer in the car, as a CarPlay **voice-based conversational app**
/// (`com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+).
///
/// Voice first, as that category requires: on connect it reads out how many sessions need
/// the driver and the first of them, and listens for an answer — yes, a reply, archive,
/// next, stop (`DrivingFlow`, which holds every rule and is tested on Linux). Anything
/// that acts on a session is confirmed out loud first. The screen underneath is a short
/// list of the sessions that need input, each row an action sheet (Approve, Reply by
/// voice, Archive) for a driver who would rather tap; a Talk button restarts the
/// conversation. Every template used — list, action sheet, voice control — is one the
/// category allows, and the stack never goes deeper than three.
///
/// **Inert until Apple grants the entitlement**, as Motet's CarPlay scene is: the scene is
/// declared in Info.plist, but without the entitlement signed in, CarPlay never connects
/// it. `App/Zimmer/CarPlay.entitlements` holds the key and is wired into nothing; see
/// ios/README.md, "CarPlay".
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var sessions: [SessionSummary] = []
    private var summaries: [Int: String] = [:]
    private var refreshTask: Task<Void, Never>?
    private var conversation: Task<Void, Never>?
    private let voice = VoiceIO()
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
        let loading = CPListTemplate(title: "Zimmer", sections: [])
        loading.emptyViewSubtitleVariants = ["Checking your sessions…"]
        interfaceController.setRootTemplate(loading, animated: false, completion: nil)
        refreshTask = Task {
            await refresh()
            if #available(iOS 26.4, *) { startConversation() }
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
            showMessage("Sign in to Zimmer on your phone first.")
            return
        }
        do {
            sessions = try await connection.api.sessions(.needsInput)
            summaries = [:]
            for session in sessions.prefix(DrivingFlow.limit) {
                if let summary = try? await connection.api.session(session.id).statusSummary?.summary {
                    summaries[session.id] = summary
                }
            }
            showList()
        } catch {
            log.error("refresh failed: \(String(describing: error), privacy: .public)")
            showMessage((error as? ZimmerError)?.userMessage ?? "Couldn't reach Zimmer.")
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
        let template = CPListTemplate(title: "Needs you", sections: [CPListSection(items: items)])
        template.emptyViewSubtitleVariants = ["Nothing needs you right now."]
        template.trailingNavigationBarButtons = [
            CPBarButton(title: "Talk") { [weak self] _ in self?.startConversation() },
        ]
        interfaceController?.setRootTemplate(template, animated: true, completion: nil)
    }

    private func showMessage(_ text: String) {
        let template = CPListTemplate(title: "Zimmer", sections: [])
        template.emptyViewSubtitleVariants = [text]
        interfaceController?.setRootTemplate(template, animated: true, completion: nil)
    }

    private func showActions(for session: SessionSummary) {
        let sheet = CPActionSheetTemplate(
            title: session.displayTitle,
            message: summaries[session.id],
            actions: [
                CPAlertAction(title: "Approve", style: .default) { [weak self] _ in
                    self?.dismissThen { await self?.perform(.followUp(sessionID: session.id, text: VoiceCommand.approvalText)) }
                },
                CPAlertAction(title: "Reply by voice", style: .default) { [weak self] _ in
                    self?.dismissThen { self?.startConversation(focusing: session.id) }
                },
                CPAlertAction(title: "Archive", style: .destructive) { [weak self] _ in
                    self?.dismissThen { await self?.perform(.archive(sessionID: session.id)) }
                },
                CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                    self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
                },
            ]
        )
        interfaceController?.presentTemplate(sheet, animated: true, completion: nil)
    }

    private func dismissThen(_ next: @escaping @MainActor () async -> Void) {
        interfaceController?.dismissTemplate(animated: true) { _, _ in
            Task { @MainActor in await next() }
        }
    }

    // MARK: - The conversation

    private func startConversation(focusing sessionID: Int? = nil) {
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
                self.interfaceController?.dismissTemplate(animated: true, completion: nil)
            }
            var effects = flow.opening()
            var misses = 0
            while !Task.isCancelled {
                for effect in effects {
                    if case .end = effect { return }
                    if case let .speak(line) = effect {
                        template.activateVoiceControlState(withIdentifier: VoiceState.speaking)
                        await self.voice.speak(line)
                    } else {
                        await self.perform(effect)
                    }
                }
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

    /// The effects that touch Zimmer. Speech and the end of the conversation are handled
    /// by the loop above.
    private func perform(_ effect: DrivingFlow.Effect) async {
        let api = AppEnvironment.shared.connection.api
        do {
            switch effect {
            case let .followUp(sessionID, text):
                _ = try await api.followUp(sessionID, prompt: text)
            case let .archive(sessionID):
                _ = try await api.archive(sessionID)
            case .speak, .end:
                return
            }
            await refresh()
        } catch {
            log.error("action failed: \(String(describing: error), privacy: .public)")
            await voice.speak((error as? ZimmerError)?.userMessage ?? "That didn't work.")
        }
    }
}
