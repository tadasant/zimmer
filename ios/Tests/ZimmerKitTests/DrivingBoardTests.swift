import XCTest
@testable import ZimmerKit

/// The car's board and rows, as `CarPlayDashboard` renders them.
final class DrivingBoardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: Int, _ title: String, _ status: SessionStatus, summary: String? = nil,
                         touched: Double = 0, pr: PullRequestLink? = nil, updated: Double = 600) -> SessionSummary {
        var session = SessionSummary(id: id, title: title, status: status, updatedAt: now.addingTimeInterval(-updated),
                                     lastUserActivityAt: now.addingTimeInterval(-touched), pullRequests: pr.map { [$0] } ?? [])
        if let summary { session.boardRow = BoardRow(statusSummary: StatusSummary(summary: summary)) }
        return session
    }

    private var green: PullRequestLink { PullRequestLink(url: URL(string: "https://github.com/tadasant/zimmer/pull/1261")!, state: "open", ci: "pass") }

    func testTheBoardSplitsDecisionsFromWorkAndCountsEverything() {
        let board = DrivingBoard(sessions: [
            session(1, "Running thing", .running),
            session(2, "Merge PR 1261?", .needsInput, touched: 60),
            session(3, "Which Postgres?", .needsInput, touched: 3_600),
            session(4, "Rotate key", .failed),
            session(5, "Nightly sweep", .waiting),
            session(6, "Old one", .archived),
        ], now: now)
        XCTAssertEqual(board.needsYou.map(\.id), [2, 3, 4], "needs input first, touched last first, then failed")
        XCTAssertEqual(board.working.map(\.id), [1, 5], "running before waiting")
        XCTAssertEqual(board.needsYouTotal, 2)
        XCTAssertEqual(board.failedTotal, 1)
        XCTAssertEqual(board.runningTotal, 1)
        XCTAssertEqual(board.waitingTotal, 1)
        XCTAssertEqual(board.summaryLine, "3 need you · 1 running · 1 waiting")
        XCTAssertFalse(board.needsNothing)
        XCTAssertEqual(DrivingBoard.empty.summaryLine, "Nothing needs you")
        XCTAssertTrue(DrivingBoard.empty.needsNothing)
    }

    func testListsStopAtWhatACarIsSureToShow() {
        let many = (1...20).map { session($0, "Session \($0)", .needsInput) }
        let board = DrivingBoard(sessions: many, now: now)
        XCTAssertEqual(board.needsYou.count, DrivingBoard.listLimit)
        XCTAssertEqual(board.needsYouTotal, 20, "the count still says how many there really are")
    }

    func testACardReadsTheSummaryAsPlainWordsOrFallsBackToTheStatus() {
        let card = DrivingCard(session(2, "Merge?", .needsInput,
                                       summary: "[PR #1261](https://github.com/x/pull/1261) is open, CI is green: it **needs your go-ahead**. The scaffold lives in `ios/App`.",
                                       pr: green), now: now)
        XCTAssertEqual(card.headline, "PR #1261 is open, CI is green: it needs your go-ahead.")
        XCTAssertEqual(card.statusLine, "Needs input · 10m")

        let bare = DrivingCard(session(3, "Which Postgres?", .needsInput), now: now)
        XCTAssertEqual(bare.headline, "Waiting for your reply.")
        XCTAssertEqual(bare.detail, "Waiting for your reply.")

        let running = DrivingCard(session(1, "Running thing", .running), now: now)
        XCTAssertEqual(running.detail, "Running · 10m", "a working session with nothing to say shows how long it has been at it")
        let busy = DrivingCard(session(1, "Running thing", .running, summary: "Building the list template; about halfway through."), now: now)
        XCTAssertEqual(busy.detail, "Building the list template; about halfway through.")
    }

    func testARowTellsLiveModeWhichSessionAndWhatToDoFirst() {
        let card = DrivingCard(session(3, "Which Postgres?", .needsInput), now: now)
        XCTAssertTrue(card.opening.contains("session 3"))
        XCTAssertTrue(card.opening.contains("\"Which Postgres?\""))
        XCTAssertTrue(card.opening.contains("needs input"))
        XCTAssertTrue(card.opening.contains("ask me what I want to do"))
    }

    func testFailedComesAfterEveryNeedsInputSession() {
        let board = DrivingBoard(sessions: [
            session(2, "Merge PR 1261?", .needsInput, touched: 1),
            session(3, "Which Postgres?", .needsInput, touched: 2),
            session(4, "Rotate key", .failed, touched: 3),
            session(5, "Fifth", .needsInput, touched: 4),
        ], now: now)
        XCTAssertEqual(board.needsYou.map(\.id), [2, 3, 5, 4])
    }

    func testACardIsFoundByIdOnEitherList() {
        let board = DrivingBoard(sessions: [session(2, "Merge?", .needsInput), session(4, "Broke", .failed), session(1, "Run", .running)], now: now)
        XCTAssertEqual(board.card(4)?.kind, .failed)
        XCTAssertEqual(board.card(1)?.kind, .running)
        XCTAssertNil(board.card(99))
    }

    func testWordsDropTheMarkdownAndStopAtTheFirstSentence() {
        XCTAssertEqual(DrivingWords.plain("## Done\n\n- **PR #1** is [open](https://x/1).\n- see `foo`"), "Done PR #1 is open. see foo")
        XCTAssertEqual(DrivingWords.plain("*emphasis* and _more_ and snake_case_name"), "emphasis and more and snake_case_name")
        XCTAssertEqual(DrivingWords.firstSentence("Bumped to v1.2 for the fix. Then more."), "Bumped to v1.2 for the fix.")
        XCTAssertEqual(DrivingWords.firstSentence("No end mark here"), "No end mark here")
        XCTAssertEqual(DrivingWords.firstSentence("Is it green? Yes."), "Is it green?")
        let long = String(repeating: "word ", count: 40) + "end."
        let cut = DrivingWords.firstSentence(long, limit: 30)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertLessThanOrEqual(cut.count, 31)
    }
}
