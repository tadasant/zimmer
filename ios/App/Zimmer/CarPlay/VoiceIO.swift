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
            speaking = continuation
            synthesizer.speak(AVSpeechUtterance(string: text))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }

    private func finishSpeaking() {
        speaking?.resume()
        speaking = nil
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
            try? await Task.sleep(nanoseconds: 250_000_000)
            let snapshot = session.transcript.snapshot()
            if snapshot.isFinal { break }
            if let changed = snapshot.lastChange, !snapshot.text.isEmpty, Date().timeIntervalSince(changed) > 1.5 { break }
        }
        let text = session.transcript.snapshot().text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Built off the main actor on purpose: the tap and the recognition handler run on
    /// audio and Speech threads, and a closure formed on the main actor would be
    /// main-actor-isolated — which Swift 6 enforces at run time, as a crash.
    nonisolated private static func startRecognition() -> RecognitionSession? {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
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
