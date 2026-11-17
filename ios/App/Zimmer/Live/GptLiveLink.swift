import Foundation
@preconcurrency import WebRTC
import ZimmerKit
import os

/// The WebRTC connection a call on the `gpt_live_claude` engine runs over: the microphone up and
/// GPT-Live's voice down as media, and its events both ways on the `oai-events` data channel —
/// the same connection the web dock's `GptLiveCall` makes in the browser.
///
/// GPT-Live takes a WebSocket only from a server holding the OpenAI key, so the phone, like the
/// browser, offers WebRTC: it makes the offer here, Zimmer starts the session with it
/// (`LiveAPI.startGptLiveSession`) and hands back OpenAI's answer, and the key never reaches the
/// phone. What to do with each event is `GptLiveConductor`'s (ZimmerKit, tested on Linux); this
/// only carries them.
///
/// **The audio is the call's engine's.** The factory gives libwebrtc `LiveWebRTCAudioDevice`
/// instead of its own voice-processing audio unit, so it opens no audio of its own: the call's
/// `LiveAudioEngine` (`start(webRTC:)`) hands it the microphone from its voice-processing input
/// and plays GPT-Live's voice on the same graph as the cues, under one `.playAndRecord`,
/// `.voiceChat` session with Bluetooth and the speaker, exactly as a Realtime call's. Apple's
/// voice processing turns down every sound outside its own unit, and on one engine the cues are
/// inside it.
///
/// Every callback libwebrtc makes arrives on its own signalling thread; each is handed to the main
/// actor, where `LiveCall` lives.
final class GptLiveLink: NSObject, @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible, LocalizedError {
        case noPeerConnection
        case noDataChannel
        case offer(String)
        case answer(String)

        var description: String {
            switch self {
            case .noPeerConnection: return "The phone could not open a WebRTC connection."
            case .noDataChannel: return "The phone could not open GPT-Live's event channel."
            case let .offer(message): return "The phone could not make a WebRTC offer: \(message)"
            case let .answer(message): return "GPT-Live's answer could not be used: \(message)"
            }
        }

        var errorDescription: String? { description }
    }

    /// One server event's text.
    var onEvent: (@MainActor (String) -> Void)?
    /// The connection failed or closed under the call.
    var onDropped: (@MainActor (String) -> Void)?

    private static let log = Logger(subsystem: "com.tadasant.zimmer", category: "gpt-live")
    /// One for the app's life, as libwebrtc expects, built on first use (`LiveCall` makes every
    /// link on the main actor). Its audio device is the call's engine (`LiveWebRTCAudioDevice`).
    nonisolated(unsafe) private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory(),
                                        audioDevice: LiveWebRTCAudioDevice.shared)
    }()

    private let peer: RTCPeerConnection
    private let channel: RTCDataChannel
    private let microphone: RTCAudioTrack
    private let lock = NSLock()
    private var closed = false

    /// Opens nothing yet: `offer()` gathers the session description to send Zimmer.
    init(muted: Bool) throws {
        let factory = Self.factory
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else {
            throw Failure.noPeerConnection
        }
        let source = factory.audioSource(with: constraints)
        let microphone = factory.audioTrack(with: source, trackId: "zimmer-mic")
        microphone.isEnabled = !muted
        peer.add(microphone, streamIds: ["zimmer"])
        let settings = RTCDataChannelConfiguration()
        guard let channel = peer.dataChannel(forLabel: "oai-events", configuration: settings) else {
            peer.close()
            throw Failure.noDataChannel
        }
        self.peer = peer
        self.channel = channel
        self.microphone = microphone
        super.init()
        peer.delegate = self
        channel.delegate = self
    }

    /// The offer to send Zimmer: the microphone track and the event channel. Like the browser's,
    /// it goes before ICE gathering finishes; GPT-Live's answer carries its own candidates.
    func offer() async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)
        let peer = self.peer
        let sdp: String = try await withCheckedThrowingContinuation { done in
            peer.offer(for: constraints) { description, error in
                if let description {
                    done.resume(returning: description.sdp)
                } else {
                    done.resume(throwing: Failure.offer(error?.localizedDescription ?? "no description"))
                }
            }
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { error in
                if let error { done.resume(throwing: Failure.offer(error.localizedDescription)) } else { done.resume() }
            }
        }
        return sdp
    }

    /// OpenAI's answer, from Zimmer: the connection comes up after this.
    func accept(answer sdp: String) async throws {
        let peer = self.peer
        let description = RTCSessionDescription(type: .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(description) { error in
                if let error { done.resume(throwing: Failure.answer(error.localizedDescription)) } else { done.resume() }
            }
        }
    }

    /// A client event, when the channel is open. Says whether it went.
    @discardableResult
    func send(_ text: String) -> Bool {
        guard channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    /// Muted, the microphone track sends nothing, as the dock's does.
    func setMuted(_ muted: Bool) {
        microphone.isEnabled = !muted
    }

    /// The connection has not failed: what the call's health asks between events. `.disconnected`
    /// counts as alive, because ICE often recovers from it by itself (a dead spot on the road, Wi-Fi
    /// to cellular); a real failure is `.failed` or `.closed`, which the delegate reports at once.
    var isConnected: Bool {
        switch peer.connectionState {
        case .failed, .closed: return false
        default: return true
        }
    }

    func close() {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        channel.delegate = nil
        peer.delegate = nil
        channel.close()
        peer.close()
    }

    private func dropped(_ reason: String) {
        guard !lock.withLock({ closed }) else { return }
        Self.log.error("gpt-live connection dropped: \(reason, privacy: .public)")
        Task { @MainActor [weak self] in self?.onDropped?(reason) }
    }
}

extension GptLiveLink: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .failed: dropped("the WebRTC connection failed")
        case .closed: dropped("the WebRTC connection closed")
        default: break
        }
    }
}

extension GptLiveLink: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed { dropped("GPT-Live's event channel closed") }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let text = String(data: buffer.data, encoding: .utf8) else { return }
        Task { @MainActor [weak self] in self?.onEvent?(text) }
    }
}
