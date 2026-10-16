import XCTest
@testable import ZimmerKit

/// The session page's pinned strip: which sections it offers, which one is lit as the page
/// scrolls, and where the page and its full-screen transcript open for each other.
final class SessionPageSectionsTests: XCTestCase {
    func testTheStripOffersOnlyTheSectionsThePageDraws() async throws {
        let fake = FakeZimmerAPI()
        // 1044 has a family and human messages; 1035 is alone, and nobody spoke to it.
        let family = try await fake.session(1044)
        XCTAssertEqual(SessionPageSection.available(in: family, hasConversation: true),
                       [.overview, .hierarchy, .humanMessages, .transcript])
        let alone = try await fake.session(1035)
        XCTAssertEqual(SessionPageSection.available(in: alone, hasConversation: true), [.overview, .transcript])
        XCTAssertEqual(SessionPageSection.available(in: alone, hasConversation: false), [.overview],
                       "no transcript chip before the conversation reads")
    }

    func testACaptureGapAloneIsWorthTheHumanMessagesChip() async throws {
        var detail = try await FakeZimmerAPI().session(1044)
        detail.humanMessages = []
        XCTAssertFalse(detail.captureGaps.isEmpty)
        XCTAssertTrue(SessionPageSection.available(in: detail, hasConversation: true).contains(.humanMessages),
                      "the row says why the list is empty, so the chip reaches it")
    }

    func testTheSectionBeingReadIsTheLastToReachTheStrip() {
        let all = SessionPageSection.allCases
        XCTAssertEqual(SessionPageSection.current(reached: [], in: all), .overview, "the top of the page")
        XCTAssertEqual(SessionPageSection.current(reached: [.overview, .hierarchy], in: all), .hierarchy)
        XCTAssertEqual(SessionPageSection.current(reached: [.overview, .hierarchy, .humanMessages, .transcript], in: all), .transcript)
        // In the page's order, whatever order the set holds them in.
        XCTAssertEqual(SessionPageSection.current(reached: [.transcript, .overview], in: all), .transcript)
    }

    func testEachSectionHasALabel() {
        XCTAssertEqual(SessionPageSection.allCases.map(\.label), ["Overview", "Hierarchy", "Human messages", "Transcript"])
        XCTAssertEqual(SessionPageSection(rawValue: "humanMessages"), .humanMessages, "the fixture's launch argument")
    }

    func testTheOtherViewOpensAtTheMessageReachedOrTheNewest() {
        let shown = [0, 2, 5, 9].map { ConversationMessage(id: $0, role: .assistant, content: "m\($0)") }
        XCTAssertNil(ConversationReading.target(above: [0, 2, 5], atEnd: true, shown: shown), "the end in view: the newest")
        XCTAssertEqual(ConversationReading.target(above: [0, 2, 5], atEnd: false, shown: shown), 5)
        // A message the other level hides is passed over for the one shown above it.
        XCTAssertEqual(ConversationReading.target(above: [0, 2, 3, 4], atEnd: false, shown: shown), 2)
        XCTAssertEqual(ConversationReading.target(above: [], atEnd: false, shown: shown), 0, "above the transcript: its first message")
        XCTAssertNil(ConversationReading.target(above: [], atEnd: false, shown: []))
    }

    func testTheLongTranscriptFixtureIsLongAndKeepsTheSampleAtItsEnd() async throws {
        let fake = FakeZimmerAPI(longTranscript: true)
        let conversation = try await fake.conversation(1044, limit: Conversation.pageSize)
        XCTAssertEqual(conversation.total, 99)
        XCTAssertFalse(conversation.truncated, "one read holds it")
        XCTAssertEqual(conversation.messages.map(\.id), Array(0..<99), "positions in order")
        XCTAssertTrue(conversation.messages.last?.content.hasPrefix("Slice 2 is open as #1294") ?? false)
        let short = try await FakeZimmerAPI().conversation(1044, limit: Conversation.pageSize)
        XCTAssertEqual(short.total, 7, "the default fixture is untouched")
    }
}
