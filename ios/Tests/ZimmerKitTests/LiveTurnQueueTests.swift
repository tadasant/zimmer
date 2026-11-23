import XCTest
@testable import ZimmerKit

/// Lines reach Zimmer in the order they were said, whatever the network does (`LiveTurnQueue`).
@MainActor
final class LiveTurnQueueTests: XCTestCase {
    func test_a_slow_line_is_not_overtaken_by_the_ones_after_it() async throws {
        let queue = LiveTurnQueue()
        let recorded = Recorded()
        queue.add {
            try? await Task.sleep(for: .milliseconds(200))
            recorded.lines.append("Merge pull request 1490?")
        }
        queue.add { recorded.lines.append("Yes") }
        queue.add { recorded.lines.append("Merging.") }
        try await wait { recorded.lines.count == 3 }
        XCTAssertEqual(recorded.lines, ["Merge pull request 1490?", "Yes", "Merging."])
    }

    func test_a_line_that_hangs_holds_up_the_next_only_for_the_patience() async throws {
        let queue = LiveTurnQueue(patience: .milliseconds(100))
        let recorded = Recorded()
        queue.add {
            try? await Task.sleep(for: .seconds(5))
            recorded.lines.append("hung")
        }
        queue.add { recorded.lines.append("Yes") }
        try await wait { recorded.lines.count == 1 }
        XCTAssertEqual(recorded.lines, ["Yes"])
    }

    @MainActor
    private final class Recorded {
        var lines: [String] = []
    }

    private func wait(for done: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(20)) }
    }
}
