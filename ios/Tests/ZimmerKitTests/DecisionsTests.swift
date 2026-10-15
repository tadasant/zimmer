import XCTest
@testable import ZimmerKit

/// Merge and Reprioritize: the two buttons that stand for a person's decision.
final class DecisionsTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private let pr = URL(string: "https://github.com/t/r/pull/7")!

    func testMergeIsOfferedOnlyOnTheNewestPRWhenItIsOpenAndGreen() {
        func session(_ prs: [PullRequestLink]) -> SessionSummary {
            SessionSummary(id: 1, title: "x", status: .needsInput, agentRuntime: "claude_code", prompt: "p", createdAt: Date(), updatedAt: Date(), pullRequests: prs)
        }
        let older = URL(string: "https://github.com/t/r/pull/6")!
        XCTAssertEqual(session([PullRequestLink(url: pr, state: "open", ci: "pass")]).mergeablePullRequest?.url, pr)
        XCTAssertNil(session([PullRequestLink(url: pr, state: "open", ci: "pending")]).mergeablePullRequest)
        XCTAssertNil(session([PullRequestLink(url: pr, state: "open")]).mergeablePullRequest, "no CI is not green")
        XCTAssertNil(session([PullRequestLink(url: pr, state: "merged", ci: "pass")]).mergeablePullRequest)
        XCTAssertNil(session([PullRequestLink(url: pr, state: "open", ci: "pass"), PullRequestLink(url: older, state: "closed")]).mergeablePullRequest,
                     "the newest PR is the one the button is about")
    }

    func testMergePostsAndReadsAnAlreadySentAnswer() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["outcome": "sent", "message": "Merge authorized. Session 9 has been told to merge.", "pr_url": "x"]) },
            { _ in Fixtures.json(200, ["outcome": "already_sent", "message": "Merge already authorized", "pr_url": "x"]) },
        ])

        let first = try await api.authorizeMerge(9)
        let second = try await api.authorizeMerge(9)

        XCTAssertEqual("\(transport.sent[0].method) \(transport.sent[0].url.path)", "POST /api/v1/sessions/9/authorize_merge")
        XCTAssertFalse(first.alreadySent)
        XCTAssertTrue(second.alreadySent)
        XCTAssertEqual(second.message, "Merge already authorized")
    }

    func testARefusedMergeCarriesTheServersReason() async throws {
        let (api, _) = client([{ _ in Fixtures.json(403, ["error": "Forbidden", "message": "This sign-in may not act as you; sign in again and allow acting as you"]) }])
        do {
            _ = try await api.authorizeMerge(9)
            XCTFail("expected a refusal")
        } catch let ZimmerError.http(status, message) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(message, "This sign-in may not act as you; sign in again and allow acting as you")
        }
    }

    func testReprioritizeNamesTheSessionThatTookTheJob() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, ["outcome": "fired", "message": "Reprioritizing in session #88",
                                                                   "session": ["id": 88, "status": "running"]]) }])

        let result = try await api.reprioritize()

        XCTAssertEqual("\(transport.sent[0].method) \(transport.sent[0].url.path)", "POST /api/v1/sessions/reprioritize")
        XCTAssertEqual(result.sessionID, 88)
    }

    func testTheFakeMergesOnceAndReusesItsReprioritizer() async throws {
        let api = FakeZimmerAPI()
        let first = try await api.authorizeMerge(1038)
        let second = try await api.authorizeMerge(1038)
        XCTAssertFalse(first.alreadySent)
        XCTAssertTrue(second.alreadySent)

        let ranker = try await api.reprioritize()
        let again = try await api.reprioritize()
        XCTAssertEqual(ranker.sessionID, again.sessionID)
    }
}
