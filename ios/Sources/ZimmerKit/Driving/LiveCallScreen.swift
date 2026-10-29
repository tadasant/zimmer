import Foundation

/// The car's call screen, a voice control template: five states, built once per call and never
/// rebuilt. It goes up when the call starts and down when it ends, and a change of state, Mute
/// included, is one `activateVoiceControlState`: every template change is one more CarPlay can
/// refuse.
///
/// CarPlay keeps the first five states a voice control template is given and ignores the rest
/// (`CPVoiceControlTemplate.init(voiceControlStates:)`). A screen built with a muted twin of every
/// call state had ten, and CarPlay dropped *speaking* and *working*. So the five are the four a
/// driver needs to tell apart — connecting, listening, speaking, working (thinking is working) —
/// and *Muted*, which shows whatever the call is doing while the microphone is off. The title is
/// the only text the template is sure to draw: a trailing bar button as a status line did not
/// render in the Simulator's CarPlay window, so there is none.
public enum LiveCallScreen {
    /// What CarPlay keeps.
    public static let maximumStates = 5

    /// Every state the screen is built with, in order: the first is the one it opens on.
    public static let identifiers = ["connecting", "listening", "speaking", "working", "muted"]

    /// The state to show for the call: Muted while the microphone is off, else the call's state.
    /// A call going idle is about to be taken down; until it is, it reads as connecting.
    public static func identifier(for state: LiveVoiceState, muted: Bool) -> String {
        if muted { return "muted" }
        switch state {
        case .idle, .connecting: return "connecting"
        case .listening: return "listening"
        case .speaking: return "speaking"
        case .thinking, .working: return "working"
        }
    }

    /// A state's title.
    public static func title(for identifier: String) -> String {
        switch identifier {
        case "listening": return LiveVoiceState.listening.label
        case "speaking": return LiveVoiceState.speaking.label
        case "working": return LiveVoiceState.working.label
        case "muted": return "Muted"
        default: return LiveVoiceState.connecting.label
        }
    }
}
