import XCTest
@testable import ZimmerKit

/// The car's board, cards and spoken lines, as `CarPlaySceneDelegate` renders them.
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
        XCTAssertEqual(card.pullRequestLine, "#1261 · open · CI green")
        XCTAssertEqual(card.spoken, "Merge? PR #1261 is open, CI is green: it needs your go-ahead.")

        let bare = DrivingCard(session(3, "Which Postgres?", .needsInput), now: now)
        XCTAssertEqual(bare.headline, "Waiting for your reply.")
        XCTAssertEqual(bare.detail, "Waiting for your reply.")

        let running = DrivingCard(session(1, "Running thing", .running), now: now)
        XCTAssertEqual(running.detail, "Running · 10m", "a working session with nothing to say shows how long it has been at it")
        let busy = DrivingCard(session(1, "Running thing", .running, summary: "Building the list template; about halfway through."), now: now)
        XCTAssertEqual(busy.detail, "Building the list template; about halfway through.")
    }

    func testTheButtonsFollowTheDecision() {
        let merge = DrivingCard(session(2, "Merge?", .needsInput, pr: green), now: now)
        XCTAssertEqual(merge.actions, [.merge(green), .talkAboutIt], "a green PR's decision is the merge")
        XCTAssertEqual(merge.more, [.goAhead, .readAloud, .archive])

        let reply = DrivingCard(session(3, "Which Postgres?", .needsInput), now: now)
        XCTAssertEqual(reply.actions, [.goAhead, .talkAboutIt])
        XCTAssertEqual(reply.more, [.readAloud, .archive])

        let pending = DrivingCard(session(3, "CI running", .needsInput,
                                          pr: PullRequestLink(url: URL(string: "https://github.com/x/pull/2")!, state: "open", ci: "pending")), now: now)
        XCTAssertEqual(pending.actions, [.goAhead, .talkAboutIt], "a PR that is not green is not offered for merge")

        let failed = DrivingCard(session(4, "Rotate key", .failed), now: now)
        XCTAssertEqual(failed.actions, [.restart, .talkAboutIt])
        XCTAssertEqual(failed.more, [.readAloud, .archive])

        let running = DrivingCard(session(1, "Running", .running), now: now)
        XCTAssertEqual(running.actions, [.talkAboutIt, .readAloud])
        XCTAssertTrue(running.more.isEmpty)
    }

    func testOnlyMergeAndArchiveAskFirstAndTrashIsNotOffered() {
        let card = DrivingCard(session(2, "Merge?", .needsInput, pr: green), now: now)
        XCTAssertEqual(DrivingAction.merge(green).confirmation(for: card), "Merge #1261? The session merges it and archives itself.")
        XCTAssertEqual(DrivingAction.archive.confirmation(for: card), "Archive Merge??")
        XCTAssertNil(DrivingAction.goAhead.confirmation(for: card))
        XCTAssertNil(DrivingAction.restart.confirmation(for: card))
        XCTAssertNil(DrivingAction.talkAboutIt.confirmation(for: card))
        XCTAssertTrue(DrivingAction.archive.isDestructive)
        XCTAssertEqual(DrivingAction.goAhead.spokenDone, "Told it to go ahead.")
        XCTAssertEqual(DrivingAction.merge(green).spokenDone, "Merge authorized.")
        XCTAssertNil(DrivingAction.talkAboutIt.spokenDone)
        XCTAssertEqual(DrivingAction.merge(green).title, "Merge #1261")
        let titles = Set((card.actions + card.more).map(\.title))
        XCTAssertFalse(titles.contains { $0.lowercased().contains("trash") })
    }

    func testTalkAboutItTellsLiveModeWhichSessionAndWhatToDoFirst() {
        let card = DrivingCard(session(3, "Which Postgres?", .needsInput), now: now)
        let opening = DrivingAction.opening(for: card)
        XCTAssertTrue(opening.contains("session 3"))
        XCTAssertTrue(opening.contains("\"Which Postgres?\""))
        XCTAssertTrue(opening.contains("needs input"))
        XCTAssertTrue(opening.contains("ask me what I want to do"))
    }

    func testTheBriefingCountsReadsTheFirstFewAndNeverSaysNothingForAFailure() {
        let board = DrivingBoard(sessions: [
            session(2, "Merge PR 1261?", .needsInput, summary: "CI is green.", touched: 1),
            session(3, "Which Postgres?", .needsInput, touched: 2),
            session(4, "Rotate key", .failed, touched: 3),
            session(5, "Fifth", .needsInput, touched: 4),
            session(1, "Running thing", .running),
            session(6, "Waiting thing", .waiting),
        ], now: now)
        XCTAssertEqual(
            Briefing.text(for: board),
            "4 sessions need you. First: Merge PR 1261? CI is green. Second: Which Postgres? Waiting for your reply. " +
                "Third: Fifth. Waiting for your reply. And 1 more. One running, one waiting."
        )
        XCTAssertEqual(Briefing.text(for: DrivingBoard.empty), "Nothing needs you.")
        let one = DrivingBoard(sessions: [session(3, "Which Postgres?", .needsInput), session(1, "A", .running), session(7, "B", .running)], now: now)
        XCTAssertEqual(Briefing.text(for: one), "One session needs you. Which Postgres? Waiting for your reply. 2 running.")
        XCTAssertEqual(Briefing.failure("Couldn't reach Zimmer."), "I couldn't check your sessions. Couldn't reach Zimmer.")
        XCTAssertEqual(board.needsYou.map(\.id), [2, 3, 5, 4], "failed comes after every needs-input session")
        XCTAssertEqual(Briefing.alert(for: board.needsYou[3]), "Zimmer: Rotate key. It failed. Failed. Restart it, or talk it through.")
        XCTAssertEqual(Briefing.alert(for: board.needsYou[0]), "Zimmer: Merge PR 1261? It needs you. CI is green.")
    }

    func testNewArrivalsAreTheOnesNotKnownBefore() {
        let before = DrivingBoard(sessions: [session(2, "Merge?", .needsInput)], now: now)
        let after = DrivingBoard(sessions: [session(2, "Merge?", .needsInput), session(3, "New", .needsInput), session(4, "Broke", .failed)], now: now)
        XCTAssertEqual(after.newlyNeedingYou(since: before.needsYouIDs).map(\.id), [3, 4])
        XCTAssertTrue(before.newlyNeedingYou(since: after.needsYouIDs).isEmpty)
        XCTAssertEqual(after.card(4)?.kind, .failed)
        XCTAssertNil(after.card(99))
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
        XCTAssertEqual(DrivingWords.sentence("Hello"), "Hello.")
        XCTAssertEqual(DrivingWords.sentence("Hello?"), "Hello?")
        XCTAssertEqual(DrivingWords.sentence("  "), "")
    }
}
