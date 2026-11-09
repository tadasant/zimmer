import Foundation

/// The car's call screen, a voice control template: five states, built once per call and never
/// rebuilt. It goes up when the call starts and down when it ends, and a change of state, Mute
/// and Send now included, is one `activateVoiceControlState`: every template change is one more
/// CarPlay can refuse.
///
/// CarPlay keeps the first five states a voice control template is given and ignores the rest
/// (`CPVoiceControlTemplate.init(voiceControlStates:)`). A screen built with a muted twin of every
/// call state had ten, and CarPlay dropped *speaking* and *working*. A state is also the only
/// thing that can change the two action buttons, so the five are whose turn it is:
///
/// - **connecting**: nobody's — the call is not up, or its microphone is lost;
/// - **listening**: the driver's, nothing heard yet. Mute and End;
/// - **hearing**: the driver's, and turn detection has heard speech it has not ended the turn on.
///   **Send now** and End: Send now takes Mute's place, so End never moves;
/// - **replying**: Zimmer's — thinking, working on a tool, or speaking. One state, because the
///   driver hears which: the thinking cue, the tool cue, the voice. Mute and End;
/// - **muted**: whatever the call is doing while the microphone is off. Mute and End.
///
/// The title is the only text the template is sure to draw: a trailing bar button as a status
/// line did not render in the Simulator's CarPlay window, so there is none. The leading bar button
/// is the gear that opens the voice settings (`CarVoiceSettings`); it is set on the template,
/// once, when the screen is built, so it takes no state and adds none.
public enum LiveCallScreen {
    /// What CarPlay keeps.
    public static let maximumStates = 5

    /// Every state the screen is built with, in order: the first is the one it opens on.
    public static let identifiers = ["connecting", "listening", "hearing", "replying", "muted"]

    /// The one state with Send now in place of Mute.
    public static let sendNowState = "hearing"

    /// The state to show for the call: Muted while the microphone is off, else the call's state.
    /// A call going idle is about to be taken down; until it is, it reads as connecting. So does
    /// a call that lost its microphone: nothing the driver says is reaching it, whatever else it
    /// is doing, and a sixth state is one CarPlay would drop.
    ///
    /// `speechHeard`: turn detection heard speech and has not ended the turn
    /// (`RealtimeConductor.canEndTurn`). Only while listening is it Send now's state: during a
    /// reply the speech may be the driver talking over it, which turn detection is cutting off,
    /// and the screen says Listening the moment it does; muted, nothing more is heard.
    public static func identifier(for state: LiveVoiceState, muted: Bool, microphoneLost: Bool = false, speechHeard: Bool = false) -> String {
        if microphoneLost { return "connecting" }
        if muted { return "muted" }
        switch state {
        case .idle, .connecting: return "connecting"
        case .listening: return speechHeard ? sendNowState : "listening"
        case .thinking, .speaking, .working: return "replying"
        }
    }

    /// Whether Send now is on the screen for this call.
    public static func offersSendNow(for state: LiveVoiceState, muted: Bool, microphoneLost: Bool, speechHeard: Bool) -> Bool {
        identifier(for: state, muted: muted, microphoneLost: microphoneLost, speechHeard: speechHeard) == sendNowState
    }

    /// A state's title.
    public static func title(for identifier: String) -> String {
        switch identifier {
        case "listening": return LiveVoiceState.listening.label
        case "hearing": return "Hearing you"
        case "replying": return "Replying"
        case "muted": return "Muted"
        default: return LiveVoiceState.connecting.label
        }
    }

    /// The Send now button. CarPlay draws only its symbol, and labels it for accessibility by
    /// the symbol alone (the drill reads "hang up" for End's `phone.down.fill`), so the symbol is
    /// both what the driver sees and what VoiceOver says: a paper plane, the send everyone knows.
    public static let sendNowTitle = "Send now"
    public static let sendNowSymbol = "paperplane.fill"
}
