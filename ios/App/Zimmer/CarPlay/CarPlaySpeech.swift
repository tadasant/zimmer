@preconcurrency import AVFoundation
import CarPlay
import Foundation
import UIKit
import ZimmerKit
import os

/// The car's own voice: the briefing when its tile is tapped, a card read aloud, and the word
/// that an action worked — never anything unasked. Speech only, never listening: listening is
/// Live Mode's, over the Realtime call. So the audio session is
/// playback, held only while a line is being said, and ducks the car's audio rather than
/// stopping it — Apple's rule for a voice-based conversational app, which may hold audio only
/// while voice is in use and must not configure recording outside the voice control template.
///
/// Quiet during a Live call: the call owns the audio session and the model is the voice then.
@MainActor
final class CarPlaySpeech: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var waiting: CheckedContinuation<Void, Never>?
    /// The utterance `waiting` waits on, so a late callback for an earlier one cannot end the
    /// next line early.
    private var current: AVSpeechUtterance?
    private var holdingAudio = false
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "carplay-speech")

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Says `text` and returns once it has been said — at once, saying nothing, while a Live
    /// call is up.
    func speak(_ text: String) async {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !LiveCall.shared.isActive else { return }
        hold()
        await withCheckedContinuation { continuation in
            finish()
            let utterance = AVSpeechUtterance(string: line)
            waiting = continuation
            current = utterance
            synthesizer.speak(utterance)
        }
        release()
    }

    /// Stops mid-word: the driver tapped something, or a call is starting.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        finish()
        release()
    }

    private func hold() {
        guard !holdingAudio else { return }
        holdingAudio = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            log.error("audio session refused: \(String(describing: error), privacy: .public)")
        }
    }

    private func release() {
        guard holdingAudio, !synthesizer.isSpeaking else { return }
        holdingAudio = false
        // A call that started meanwhile holds the session now; leave it to the call.
        guard !LiveCall.shared.isActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finish(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finish(id) }
    }

    /// Resumes the waiting `speak` — only for its own utterance when one is named.
    private func finish(_ utterance: ObjectIdentifier? = nil) {
        if let utterance, let current, ObjectIdentifier(current) != utterance { return }
        waiting?.resume()
        waiting = nil
        current = nil
    }
}

/// The symbols the car's templates draw. CarPlay renders template images itself, in the car's
/// scale and appearance, so a symbol image is enough; the sizes are the guide's.
enum CarPlayImages {
    /// A grid tile's icon (40pt in the guide).
    static func tile(_ name: String) -> UIImage {
        symbol(name, pointSize: 40, weight: .medium)
    }

    /// A tab's icon (24pt).
    static func tab(_ name: String) -> UIImage {
        symbol(name, pointSize: 24, weight: .medium)
    }

    /// A list row's leading image.
    static func row(_ name: String) -> UIImage {
        symbol(name, pointSize: 28, weight: .regular)
    }

    /// A bar button's image.
    static func bar(_ name: String) -> UIImage {
        symbol(name, pointSize: 20, weight: .medium)
    }

    /// The voice control template's picture for a call state (150pt in the guide).
    static func voice(_ state: LiveVoiceState, muted: Bool) -> UIImage {
        let name: String
        switch state {
        case .idle, .connecting: name = "antenna.radiowaves.left.and.right"
        case .listening: name = muted ? "mic.slash.fill" : "mic.fill"
        case .thinking: name = "ellipsis.bubble.fill"
        case .speaking: name = "waveform"
        case .working: name = "gearshape.2.fill"
        }
        return symbol(name, pointSize: 120, weight: .regular)
    }

    /// The picture the car's own voice speaks under.
    static var announcement: UIImage {
        symbol("speaker.wave.2.fill", pointSize: 120, weight: .regular)
    }

    /// One of the voice control template's action buttons (iOS 26.4+): a `CPButton`, which takes
    /// an image and carries its words as a title. `CPTextButton` is a different class and is not
    /// one of these.
    @available(iOS 26.4, *)
    static func actionButton(_ title: String, symbol name: String, handler: @escaping (CPButton) -> Void) -> CPButton {
        let button = CPButton(image: symbol(name, pointSize: 24, weight: .medium), handler: handler)
        button.title = title
        return button
    }

    static func symbol(_ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return UIImage(systemName: name, withConfiguration: configuration) ?? UIImage(systemName: "circle", withConfiguration: configuration) ?? UIImage()
    }
}
