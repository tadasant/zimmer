import Foundation

/// The call the car left on the phone, and the phone's way to it.
///
/// The audio needs no help: when the CarPlay scene goes, the call carries on. This is the screen.
/// A driver who has pulled in and picked up the phone should find the call in front of them, and
/// everything here is about when not to do that:
///
/// - **It follows the audio.** A route is armed by a call that is up when the car goes, which is
///   exactly the call that carries on: Connecting… included, a retry or a call that has just
///   ended (the gear's included) not, because neither has a call left to go to.
/// - **It waits out a blip.** CarPlay drops with the car moving, through a cable or a Bluetooth
///   flap, so nothing moves until the car has been gone for `settle`. The car coming back forgets
///   the route, so a flap leaves the phone where it was and no route armed.
/// - **It waits for the front.** iOS will not bring an app forward for it, so the route waits for
///   the next foreground, for as long as the call lives. It is good for that call and for one
///   landing: the call ending forgets it, and it is checked against the call again on arrival.
/// - **It takes nothing away.** A landing only ever opens: it closes nothing, so it cannot lose
///   what was typed, and while anything is up over the tabs, or the keyboard is, it waits.
/// - **The person wins.** Opening a session from a push or a link forgets the route.
///
/// A landing changes nothing about the call: no request, no microphone, no audio, no sound.
public struct LiveHandover: Sendable, Equatable {
    /// How long the car has to stay gone. Long enough for a bad cable or a Bluetooth blip, short
    /// enough that someone who unplugged with the app open sees it happen.
    public static let settle: TimeInterval = 3

    public struct Route: Sendable, Equatable {
        public let conversation: Int
        public let leftAt: TimeInterval
    }

    /// What the phone is showing, as far as a landing cares.
    public enum Screen: Sendable, Equatable {
        /// The tabs, with nothing over them.
        case free
        /// A sheet, a dialog or the keyboard: the person is doing something.
        case busy
        /// Live's own list, with its sheet already up.
        case liveList
        /// One conversation's thread, with Live's sheet up. It may hold a draft.
        case liveThread(Int)
    }

    public enum Step: Sendable, Equatable {
        /// No route, or none left.
        case nothing
        /// Not yet: ask again.
        case wait
        /// Open this conversation's thread. The route is spent.
        case land(Int)
    }

    public private(set) var route: Route?

    public init() {}

    /// The CarPlay scene went away, with or without a call up.
    public mutating func carLeft(conversation: Int?, callIsActive: Bool, at now: TimeInterval) {
        route = callIsActive ? conversation.map { Route(conversation: $0, leftAt: now) } : nil
    }

    /// The CarPlay scene connected: the call is the car's again.
    public mutating func carCameBack() {
        route = nil
    }

    public mutating func callEnded() {
        route = nil
    }

    /// The person opened something on purpose: a push, a link.
    public mutating func personChoseElsewhere() {
        route = nil
    }

    /// What to do now. `callConversation` and `callIsActive` are the call as it stands, not as it
    /// was: the route is only as good as the call it was armed for.
    public mutating func step(callConversation: Int?, callIsActive: Bool, inFront: Bool, screen: Screen, at now: TimeInterval) -> Step {
        guard let route else { return .nothing }
        guard callIsActive, callConversation == route.conversation else {
            self.route = nil
            return .nothing
        }
        guard inFront, now - route.leftAt >= Self.settle else { return .wait }
        switch screen {
        case .liveThread(route.conversation):
            self.route = nil
            return .nothing
        case .busy, .liveThread:
            return .wait
        case .free, .liveList:
            self.route = nil
            return .land(route.conversation)
        }
    }
}
