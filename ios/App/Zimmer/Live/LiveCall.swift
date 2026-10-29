import Foundation
import ZimmerKit
import os

/// The one voice call the app can have, shared by the phone's screens and the CarPlay scene — a
/// call started in one carries on in the other.
///
/// Starting a call turns voice on for its conversation first (`POST …/mode`), so Enable voice on
/// a typed thread, Talk on a spoken one and CarPlay's Resume all take the same path: Zimmer
/// mints a secret only for a conversation in voice, with instructions written for speech.
///
/// Every request the call makes names the client driving it: `carplay` for a call the car
/// started or took over, `ios` otherwise. Zimmer records it on the conversation, and from the
/// car the live model's instructions say the person is driving.
///
/// The audio never touches Zimmer. Zimmer mints a short-lived OpenAI Realtime secret whose
/// session config it chose (`POST /live_conversations/:id/client_secret`); the phone opens a
/// WebSocket to OpenAI's `websocket_url` with it, streams the microphone up as
/// `input_audio_buffer.append`, and plays `response.output_audio.delta` back. What to do with
/// every server event is `RealtimeConductor`'s call (ZimmerKit, tested on Linux): function calls
/// are relayed to Zimmer and answered, transcript lines recorded, `response.create` sent once.
@MainActor
final class LiveCall: ObservableObject {
    static let shared = LiveCall()

    @Published private(set) var state: LiveVoiceState = .idle
    @Published private(set) var conversationID: Int?
    @Published private(set) var muted = false
    @Published private(set) var lastError: String?
    /// Bumped on every recorded line or tool call, so an open thread knows to read again.
    @Published private(set) var activity = 0

    private var conductor = RealtimeConductor()
    /// An opening line given while the call was still connecting: sent once it is up.
    private var pendingOpening: String?
    private var socket: URLSessionWebSocketTask?
    private let audio = LiveAudioEngine()
    /// Moves on with every start and hang-up, so a late answer from an old call is ignored.
    private var generation = 0
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "live-call")

    /// The phone or the car: which client is driving the call.
    private(set) var surface: ClientSource.Surface = .ios

    private var api: any LiveAPI { AppEnvironment.shared.connection.api.live(from: surface) }

    var isActive: Bool { state != .idle }

    func isActive(for conversation: Int) -> Bool { isActive && conversationID == conversation }

    /// `voiceIsOn`: the caller has just turned voice on, so a second `POST …/mode` is not raced
    /// against a Type instead pressed while the call connects.
    ///
    /// `opening`: a line to put to the model as soon as the call is up, as if the person had
    /// typed it — a tapped session row in the car, which names that session. Recorded
    /// on the thread as a user turn, so the transcript carries why the model answered as it did.
    /// On a call already running for this conversation it is sent at once.
    ///
    /// `surface`: the client starting it. A call already running for this conversation is
    /// handed over to it (`carryOn(on:)`).
    func start(_ conversation: Int, voiceIsOn: Bool = false, opening: String? = nil, from surface: ClientSource.Surface = .ios) async {
        if isActive(for: conversation) {
            await carryOn(on: surface)
            // Hung up, or replaced, while the hand-over was answered.
            guard isActive(for: conversation) else { return }
            if let opening {
                // Still connecting: there is no socket to send on yet; the start under way sends it.
                if state == .connecting { pendingOpening = opening } else { open(with: opening) }
            }
            return
        }
        hangUp()
        generation += 1
        let mine = generation
        self.surface = surface
        conversationID = conversation
        conductor = RealtimeConductor()
        lastError = nil
        muted = false
        state = .connecting
        do {
            if !voiceIsOn { try await turnVoiceOn(conversation) }
            guard mine == generation else { return }
            let mintedFor = surface
            let secret = try await mintSecret(conversation)
            guard mine == generation else { return }
            conductor = RealtimeConductor(listening: secret.listening)
            var request = URLRequest(url: secret.websocketURL)
            request.setValue("Bearer \(secret.clientSecret)", forHTTPHeaderField: "Authorization")
            let task = URLSession.shared.webSocketTask(with: request)
            socket = task
            task.resume()
            receive(task, generation: mine)
            let audioToken = try await audio.start(
                frames: { [weak self] pcm in Task { @MainActor in self?.sendAudio(pcm, generation: mine) } },
                failed: { [weak self] message in Task { @MainActor in self?.fail(message, generation: mine) } }
            )
            // Hung up, or replaced by a newer call, while the microphone was opening: close only
            // what this start opened.
            guard mine == generation else { audio.stop(token: audioToken); return }
            state = .listening
            // Handed over while connecting, after the secret was asked for: its instructions
            // name the client that started the call, so bring them up to the one driving it.
            if surface != mintedFor { await refreshSession() }
            guard mine == generation else { return }
            let first = pendingOpening ?? opening
            pendingOpening = nil
            if let first { open(with: first) }
        } catch is CancellationError {
            return
        } catch {
            fail(Self.describe(error), generation: mine)
        }
    }

    func hangUp() {
        generation += 1
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        audio.stop()
        state = .idle
        muted = false
        pendingOpening = nil
    }

    /// Put `text` to the model as a typed line and ask for its reply (`RealtimeConductor.open`).
    private func open(with text: String) {
        guard let conversation = conversationID else { return }
        let mine = generation
        apply(conductor.open(with: text), generation: mine)
        Task {
            _ = try? await api.recordLiveTurn(conversation, role: .user, content: text, gated: false)
            guard mine == generation else { return }
            activity += 1
        }
    }

    /// Muted, the microphone sends silence rather than nothing (`RealtimeConductor.appendAudio`).
    func toggleMute() {
        muted.toggle()
    }

    /// The Live settings or guidance changed (the settings screen saved): bring an open call up
    /// to them with the `session.update` Zimmer builds. The model, voice and reasoning effort
    /// stay as they are until the next call; OpenAI fixes those for a call's life.
    func refreshSession() async {
        guard isActive, socket != nil, let conversation = conversationID else { return }
        let mine = generation
        do {
            let session = try await api.liveSessionUpdate(conversation)
            guard mine == generation else { return }
            send(RealtimeConductor.sessionUpdate(session))
        } catch {
            let message = Self.describe(error)
            log.error("live session update failed: \(message, privacy: .public)")
            guard mine == generation else { return }
            lastError = "The new Live settings did not reach this call: \(message)"
        }
    }

    /// The call moved between the phone and the car: from now on its requests name `surface`.
    /// The `session.update` Zimmer builds records the client asking for it, so asking for one
    /// both tells Zimmer and brings the open call up to instructions that say where the person
    /// is. A call still connecting is brought up to them by the start under way, once its
    /// socket is open.
    func carryOn(on surface: ClientSource.Surface) async {
        guard isActive, surface != self.surface else { return }
        self.surface = surface
        await refreshSession()
    }

    // MARK: - Internals

    /// A no-op when it is on already. A server from before voice folded into Live Mode has no
    /// such route (404), and there a voice conversation needs nothing switched.
    private func turnVoiceOn(_ conversation: Int) async throws {
        do {
            _ = try await api.setLiveMode(conversation, mode: .voice)
        } catch let ZimmerError.http(status, _) where status == 404 {
            return
        }
    }

    /// The conversation may still be reading its AGENTS.md (409); give it a moment.
    private func mintSecret(_ conversation: Int) async throws -> LiveClientSecret {
        for _ in 0..<6 {
            do {
                return try await api.liveClientSecret(conversation)
            } catch let ZimmerError.http(status, message) where status == 409 && (message ?? "").localizedCaseInsensitiveContains("still reading") {
                try await Task.sleep(for: .milliseconds(1_500))
            }
        }
        throw ZimmerError.http(status: 409, message: "The conversation is taking too long to get ready.")
    }

    private func sendAudio(_ pcm: Data, generation: Int) {
        guard generation == self.generation, !pcm.isEmpty else { return }
        send(RealtimeConductor.appendAudio(pcm, muted: muted))
    }

    private func send(_ event: JSONValue) {
        socket?.send(.string(event.encoded())) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.log.error("realtime send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self] result in
            let text: String? = switch result {
            case let .success(.string(string)): string
            case let .success(.data(data)): String(data: data, encoding: .utf8)
            default: nil
            }
            let failure: String? = if case let .failure(error) = result { error.localizedDescription } else { nil }
            Task { @MainActor in
                guard let self, generation == self.generation else { return }
                if let failure {
                    self.fail("The call dropped: \(failure)", generation: generation)
                    return
                }
                if let text, let event = JSONValue.parse(text) {
                    let effects = self.conductor.handle(event)
                    self.apply(effects, generation: generation)
                }
                self.receive(task, generation: generation)
            }
        }
    }

    private func apply(_ effects: [RealtimeConductor.Effect], generation: Int) {
        for effect in effects {
            switch effect {
            case let .send(event):
                send(event)
            case let .relay(callID, name, arguments):
                relay(callID: callID, name: name, arguments: arguments, generation: generation)
            case let .record(role, text):
                guard let conversation = conversationID else { continue }
                Task {
                    _ = try? await api.recordLiveTurn(conversation, role: role, content: text, gated: false)
                    activity += 1
                }
            case let .hear(itemID, text):
                hear(itemID: itemID, text: text, generation: generation)
            case let .play(pcm):
                audio.play(pcm)
            case .replyStarted:
                audio.replyStarted()
            case let .interrupt(itemID):
                let heard = audio.stopPlayback()
                send(RealtimeConductor.truncate(itemID: itemID, audioEndMs: heard))
            case let .state(next):
                // A reply coming through means the call recovered from whatever went wrong.
                if next == .speaking { lastError = nil }
                state = next
            case let .failure(message):
                log.error("realtime error: \(message, privacy: .public)")
                lastError = message
            }
        }
    }

    /// Gated: Zimmer decides whether the call answers this line. Unreachable, it is answered — a
    /// stray reply beats a call gone quiet.
    private func hear(itemID: String?, text: String, generation: Int) {
        guard let conversation = conversationID else { return }
        Task {
            let heard = try? await api.recordLiveTurn(conversation, role: .user, content: text, gated: true)
            guard generation == self.generation else { return }
            if heard?.dropped != true { activity += 1 }
            apply(conductor.heard(itemID: itemID, respond: heard?.respond ?? true), generation: generation)
        }
    }

    private func relay(callID: String, name: String, arguments: String, generation: Int) {
        guard let conversation = conversationID else { return }
        Task {
            var result: LiveToolResult?
            var failure: String?
            do {
                result = try await api.relayLiveToolCall(conversation, name: name, arguments: arguments, callID: callID)
            } catch {
                failure = Self.describe(error)
            }
            guard generation == self.generation else { return }
            activity += 1
            let effects = conductor.relayed(callID: callID, result: result, failure: failure)
            apply(effects, generation: generation)
        }
    }

    private func fail(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        log.error("live call ended: \(message, privacy: .public)")
        hangUp()
        lastError = message
    }

    private static func describe(_ error: Error) -> String {
        if let zimmer = error as? ZimmerError { return zimmer.userMessage }
        if let audio = error as? LiveAudioEngine.Failure { return audio.description }
        return error.localizedDescription
    }
}
