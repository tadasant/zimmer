import Foundation

/// What a CarPlay control runs when the driver taps it, safe on whatever thread CarPlay taps from.
///
/// A closure written inside a `@MainActor` type and handed to an Objective-C API, as every CarPlay
/// handler is, opens with a compiler-inserted check that it is on the main actor: called off the
/// main thread, it traps, and the app dies before the closure's first line runs.
/// `MainActor.assumeIsolated` traps the same way. Nothing here relies on which thread CarPlay
/// calls from. The closure CarPlay is given belongs to no actor, and hops to the main actor before
/// it does anything.
///
/// The hop costs a tap one turn of the main queue, which nobody can feel. `arrived` runs first, on
/// CarPlay's thread, and says which thread that was, so the log can tell how far a tap got and
/// which of CarPlay's controls call from elsewhere.
public enum CarPlayTap {
    /// Run `action` on the main actor, from any thread.
    public static func run(arrived: (@Sendable (_ onMain: Bool) -> Void)? = nil, _ action: @escaping @MainActor @Sendable () -> Void) {
        arrived?(Thread.isMainThread)
        Task { @MainActor in action() }
    }

    /// A handler for a control that passes itself to it, as `CPBarButton` and `CPButton` do.
    public static func handler<Control>(arrived: (@Sendable (_ onMain: Bool) -> Void)? = nil,
                                        _ action: @escaping @MainActor @Sendable () -> Void) -> (Control) -> Void {
        { _ in run(arrived: arrived, action) }
    }
}
