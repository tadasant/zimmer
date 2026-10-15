import Foundation
import ZimmerKit
import os

/// The one Live Voice call the app can have, shared by the phone's screens and the CarPlay
/// scene — a call started in one carries on in the other.
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
    private var socket: URLSessionWebSocketTask?
    private let audio = LiveAudioEngine()
    /// Moves on with every start and hang-up, so a late answer from an old call is ignored.
    private var generation = 0
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "live-call")

    private var api: ZimmerAPI { AppEnvironment.shared.connection.api }

    var isActive: Bool { state != .idle }

    func isActive(for conversation: Int) -> Bool { isActive && conversationID == conversation }

    func start(_ conversation: Int) async {
        if isActive(for: conversation) { return }
        hangUp()
        generation += 1
        let mine = generation
        conversationID = conversation
        conductor = RealtimeConductor()
        lastError = nil
        muted = false
        state = .connecting
        do {
            let secret = try await mintSecret(conversation)
            guard mine == generation else { return }
            var request = URLRequest(url: secret.websocketURL)
            request.setValue("Bearer \(secret.clientSecret)", forHTTPHeaderField: "Authorization")
            let task = URLSession.shared.webSocketTask(with: request)
            socket = task
            task.resume()
            receive(task, generation: mine)
            try await audio.start(
                frames: { [weak self] pcm in Task { @MainActor in self?.sendAudio(pcm, generation: mine) } },
                failed: { [weak self] message in Task { @MainActor in self?.fail(message, generation: mine) } }
            )
            guard mine == generation else { audio.stop(); return }
            state = .listening
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
    }

    func toggleMute() {
        muted.toggle()
    }

    // MARK: - Internals

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
        guard generation == self.generation, !muted, !pcm.isEmpty else { return }
        send(RealtimeConductor.appendAudio(pcm))
    }

    private func send(_ event: JSONValue) {
        socket?.send(.string(event.encoded())) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.log.error("realtime send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self] result in
            var text: String?
            var failure: String?
            switch result {
            case let .success(.string(string)): text = string
            case let .success(.data(data)): text = String(data: data, encoding: .utf8)
            case .success: break
            case let .failure(error): failure = error.localizedDescription
            }
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
                    _ = try? await api.recordLiveTurn(conversation, role: role, content: text)
                    activity += 1
                }
            case let .play(pcm):
                audio.play(pcm)
            case .stopPlayback:
                audio.stopPlayback()
            case let .state(next):
                state = next
            case let .failure(message):
                lastError = message
            }
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
