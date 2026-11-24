import Foundation

/// A call's finished lines, sent to Zimmer one at a time and in the order they were said.
///
/// Each line is a request of its own. Sent side by side they land in whatever order the network
/// gives them, and a question can be recorded after its answer. The web dock keeps the same order in
/// `GptLiveCall.recordTurn` (app/javascript/lib/gpt_live_call.js).
///
/// A line waits at most `patience` for the one before it, so a request that hangs holds nothing
/// up for long.
@MainActor
public final class LiveTurnQueue {
    @MainActor
    private final class Slot {
        var done = false
    }

    private let patience: Duration
    private var last: Slot?

    public init(patience: Duration = .seconds(2)) {
        self.patience = patience
    }

    public func add(_ send: @escaping @MainActor () async -> Void) {
        let previous = last
        let slot = Slot()
        last = slot
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: patience)
        Task { @MainActor in
            while let previous, !previous.done, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            await send()
            slot.done = true
        }
    }
}
