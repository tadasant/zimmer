import CarPlay
import Combine
import Foundation
import ZimmerKit

/// Live Mode in the car, voice on: a section on the CarPlay list that starts a new conversation
/// or resumes the open one — typed until now or not; the call turns voice on — and a call screen
/// that follows the call's state and hangs it up.
///
/// The call is `LiveCall.shared` — the same one the phone's Live screen drives — so a call
/// started at the desk carries on in the car and the other way round. Inert, like the rest of
/// the scene, until Apple grants the voice-based conversational entitlement
/// (tadasant/zimmer#1273).
@MainActor
final class CarPlayLive {
    weak var interfaceController: CPInterfaceController?
    /// The open Live Mode conversation, read with the rest of the list.
    private(set) var current: Int?
    private var watching: AnyCancellable?
    /// The list redraws the section when a call starts or ends.
    var onChange: (() -> Void)?
    private var activeWatch: AnyCancellable?
    private let call = LiveCall.shared

    init() {
        // LiveCall is main-actor and publishes from there.
        activeWatch = call.$state.map { $0 != .idle }.removeDuplicates().dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    /// Read which Live Mode conversation is open, for the list's Resume row.
    func refresh() async {
        current = try? await AppEnvironment.shared.connection.api.liveConversations().current
    }

    func section() -> CPListSection {
        var items: [CPListItem] = []
        if call.isActive, let conversation = call.conversationID {
            let back = CPListItem(text: "Back to the call", detailText: "Voice is on")
            back.handler = { [weak self] _, completion in
                self?.showCall(conversation)
                completion()
            }
            items.append(back)
        } else {
            let fresh = CPListItem(text: "New conversation", detailText: "Talk to Zimmer; slow work becomes a session")
            fresh.handler = { [weak self] _, completion in
                self?.start(resuming: nil)
                completion()
            }
            items.append(fresh)
            if let current {
                let resume = CPListItem(text: "Resume conversation", detailText: "Pick up where you left off")
                resume.handler = { [weak self] _, completion in
                    self?.start(resuming: current)
                    completion()
                }
                items.append(resume)
            }
        }
        return CPListSection(items: items, header: "Live Mode", sectionIndexTitle: nil)
    }

    private func start(resuming conversation: Int?) {
        Task {
            do {
                let id: Int
                if let conversation {
                    id = conversation
                } else {
                    id = try await AppEnvironment.shared.connection.api.startLiveConversation(.voice).id
                }
                current = id
                showCall(id)
                await call.start(id)
            } catch {
                showMessage((error as? ZimmerError)?.userMessage ?? "Couldn't start the call.")
            }
        }
    }

    private func showCall(_ conversation: Int) {
        let status = CPListItem(text: "Live Mode", detailText: call.state.label)
        let mute = CPListItem(text: call.muted ? "Unmute" : "Mute", detailText: nil)
        mute.handler = { [weak self] item, completion in
            self?.call.toggleMute()
            (item as? CPListItem)?.setText(self?.call.muted == true ? "Unmute" : "Mute")
            completion()
        }
        let hangUp = CPListItem(text: "Hang up", detailText: nil)
        hangUp.handler = { [weak self] _, completion in
            self?.call.hangUp()
            self?.interfaceController?.popTemplate(animated: true, completion: nil)
            completion()
        }
        let template = CPListTemplate(title: "Live Mode", sections: [CPListSection(items: [status, mute, hangUp])])
        // LiveCall is main-actor and publishes from there.
        watching = call.$state.combineLatest(call.$lastError).sink { state, error in
            MainActor.assumeIsolated {
                status.setDetailText(state == .idle ? (error ?? state.label) : state.label)
            }
        }
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func showMessage(_ text: String) {
        let template = CPListTemplate(title: "Live Mode", sections: [])
        template.emptyViewSubtitleVariants = [text]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
}
