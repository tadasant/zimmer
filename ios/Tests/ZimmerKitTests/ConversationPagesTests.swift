import XCTest
@testable import ZimmerKit

/// The session page's conversation: the newest window joined to the pages read back, by position.
final class ConversationPagesTests: XCTestCase {
    /// Messages at positions `range` of a conversation `total` long.
    private func window(_ range: Range<Int>, total: Int) -> Conversation {
        Conversation(
            messages: range.map { ConversationMessage(id: $0, role: .user, content: "m\($0)") },
            total: total,
            truncated: range.lowerBound > 0,
            firstPosition: range.lowerBound
        )
    }

    private func ids(_ pages: ConversationPages) -> [Int] {
        pages.shown?.messages.map(\.id) ?? []
    }

    func testAPollAfterReadingBackKeepsEveryMessage() {
        var pages = ConversationPages()
        pages.receive(window(100..<300, total: 300))
        pages.prepend(window(0..<100, total: 300), before: 100)
        XCTAssertEqual(ids(pages), Array(0..<300))

        // Five arrive and the window is read whole again: what slid out of it stays on screen.
        pages.receive(window(105..<305, total: 305))
        XCTAssertEqual(ids(pages), Array(0..<305))
        XCTAssertEqual(pages.shown?.firstPosition, 0)

        // And again, past what the pages read back used to end at.
        pages.receive(window(110..<310, total: 310))
        XCTAssertEqual(ids(pages), Array(0..<310))
    }

    func testATailReadJoinsTheNewestWindow() {
        var pages = ConversationPages()
        pages.receive(window(100..<300, total: 300))
        pages.prepend(window(0..<100, total: 300), before: 100)
        XCTAssertTrue(pages.receiveTail(window(283..<303, total: 303)))
        XCTAssertEqual(ids(pages), Array(0..<303))
        XCTAssertEqual(pages.shown?.total, 303)
    }

    func testATailThatLeavesAGapAsksForAWholeRead() {
        var pages = ConversationPages()
        pages.receive(window(100..<300, total: 300))
        XCTAssertFalse(pages.receiveTail(window(330..<350, total: 350)))
        XCTAssertEqual(ids(pages), Array(100..<300))
    }

    func testMoreArrivingThanTheWindowHoldsDropsThePagesReadBack() {
        var pages = ConversationPages()
        pages.receive(window(100..<300, total: 300))
        pages.prepend(window(0..<100, total: 300), before: 100)
        pages.receive(window(400..<600, total: 600))
        XCTAssertEqual(ids(pages), Array(400..<600))
        XCTAssertEqual(pages.shown?.firstPosition, 400)
    }

    func testAShorterConversationDropsThePagesReadBack() {
        var pages = ConversationPages()
        pages.receive(window(100..<300, total: 300))
        pages.prepend(window(0..<100, total: 300), before: 100)
        XCTAssertFalse(pages.receiveTail(window(260..<280, total: 280)))
        pages.receive(window(80..<280, total: 280))
        XCTAssertEqual(ids(pages), Array(80..<280))
    }

    func testAPageReadTwiceIsShownOnce() {
        var pages = ConversationPages()
        pages.receive(window(100..<300, total: 300))
        pages.prepend(window(0..<100, total: 300), before: 100)
        pages.prepend(window(0..<100, total: 300), before: 100)
        XCTAssertEqual(ids(pages), Array(0..<300))
    }

    func testAPositionTheServerSkippedIsNotAGap() {
        // A message of a role the app does not draw keeps its position and is not shown.
        var pages = ConversationPages()
        var newest = window(100..<300, total: 300)
        newest.messages.removeAll { $0.id == 150 }
        pages.receive(newest)
        pages.prepend(window(0..<100, total: 300), before: 100)
        pages.receive(window(170..<370, total: 370))
        XCTAssertEqual(ids(pages), Array(0..<150) + Array(151..<370))
    }
}
