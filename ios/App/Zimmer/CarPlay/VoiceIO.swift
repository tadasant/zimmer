@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech
import os

/// Speaking and listening for the CarPlay conversation.
///
/// The audio session is held only while the conversation runs (`begin` … `end`): a
/// voice-based conversational app may not keep audio open when voice is not in use, and the
/// driver's own audio should come back the moment it ends.
@MainActor
final class VoiceIO: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var speaking: CheckedContinuation<Void, Never>?
    /// The utterance `speaking` waits on, so a late callback for an earlier one (after
    /// `end()` or a stop) cannot resume the next `speak` early — which would start the
    /// recogniser while the app is still talking.
    private var current: AVSpeechUtterance?
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "carplay-voice")

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func begin() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .allowBluetooth, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            log.error("audio session refused: \(String(describing: error), privacy: .public)")
        }
    }

    func end() {
        synthesizer.stopSpeaking(at: .immediate)
        finishSpeaking()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func speak(_ text: String) async {
        await withCheckedContinuation { continuation in
            finishSpeaking()
            let utterance = AVSpeechUtterance(string: text)
            speaking = continuation
            current = utterance
            synthesizer.speak(utterance)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finishSpeaking(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finishSpeaking(id) }
    }

    /// Resumes the waiting `speak` — only for its own utterance when one is named.
    private func finishSpeaking(_ utterance: ObjectIdentifier? = nil) {
        if let utterance, let current, ObjectIdentifier(current) != utterance { return }
        speaking?.resume()
        speaking = nil
        current = nil
    }

    /// Whether this phone can recognise speech without a server. When it can't, the car
    /// says so rather than listening for nothing.
    nonisolated static var canListen: Bool {
        guard let recognizer = SFSpeechRecognizer() else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    /// One dictated phrase: listens until the recogniser calls it final, the driver has
    /// been quiet for a moment, or `timeout` passes. Nil when permission is missing or
    /// nothing was heard.
    func listen(timeout: TimeInterval = 8) async -> String? {
        guard await Self.authorize() else {
            log.info("speech or microphone permission missing")
            return nil
        }
        guard let session = Self.startRecognition() else { return nil }
        defer { session.stop() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                break  // cancelled: stop listening now, not at the deadline
            }
            let snapshot = session.transcript.snapshot()
            if snapshot.isFinal { break }
            if let changed = snapshot.lastChange, !snapshot.text.isEmpty, Date().timeIntervalSince(changed) > 1.5 { break }
        }
        let text = session.transcript.snapshot().text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// `nonisolated`, like `startRecognition`: Speech calls the authorization handler on a
    /// background queue, and a handler formed on the main actor would be checked as
    /// main-actor code there — a Swift 6 run-time crash on the first listen.
    nonisolated private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// `nonisolated` on purpose, though it is called from the main actor: the tap and the
    /// recognition handler run on audio and Speech threads, and a closure formed in a
    /// main-actor function would be main-actor-isolated — which Swift 6 enforces at run
    /// time, as a crash. Formed here, they carry no isolation.
    ///
    /// Recognition is on the device only. A driver's reply is the text of a message to a
    /// session, and server recognition would send that audio to Apple; where the device
    /// cannot recognise on its own, the car does not listen at all.
    nonisolated private static func startRecognition() -> RecognitionSession? {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return nil
        }
        let transcript = Transcript()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result { transcript.update(result.bestTranscription.formattedString, final: result.isFinal) }
            if error != nil { transcript.update(nil, final: true) }
        }
        return RecognitionSession(engine: engine, request: request, task: task, transcript: transcript)
    }
}

/// The recogniser's running answer, written from the Speech thread and read on the main actor.
final class Transcript: @unchecked Sendable {
    struct Snapshot { let text: String; let isFinal: Bool; let lastChange: Date? }

    private let lock = NSLock()
    private var text = ""
    private var isFinal = false
    private var lastChange: Date?

    func update(_ newText: String?, final: Bool) {
        lock.withLock {
            if let newText, newText != text { text = newText; lastChange = Date() }
            if final { isFinal = true }
        }
    }

    func snapshot() -> Snapshot { lock.withLock { Snapshot(text: text, isFinal: isFinal, lastChange: lastChange) } }
}

final class RecognitionSession: @unchecked Sendable {
    let transcript: Transcript
    private let engine: AVAudioEngine
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let task: SFSpeechRecognitionTask

    init(engine: AVAudioEngine, request: SFSpeechAudioBufferRecognitionRequest, task: SFSpeechRecognitionTask, transcript: Transcript) {
        self.engine = engine
        self.request = request
        self.task = task
        self.transcript = transcript
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request.endAudio()
        task.cancel()
    }
}
