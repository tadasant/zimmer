import XCTest
@testable import ZimmerKit

/// Slice G: what the web session page has beyond the slices before it — a Copy button on each
/// code block, the composer's "/" typeahead of the session's skills, and the scheduling class
/// and precedence its desktop metadata block edits.
final class TranscriptParityTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    }

    // MARK: - Code blocks

    func testTheServersToolTrafficAndFencedWordsAreCodeBlocks() async throws {
        // As `Session#formatted_conversation` writes them: a tool call's command and a tool
        // result each in a fence, and an agent's own fenced block.
        let (api, _) = client([{ _ in Fixtures.json(200, [
            "messages": [
                ["role": "assistant", "content": "**Using tool: Bash**\nRun the tests\n```\nbin/rails test\n```", "has_tool_use": true, "has_tool_result": false],
                ["role": "user", "content": "**Tool Result:**\n```\n12 runs, 0 failures\n```", "has_tool_use": false, "has_tool_result": true],
                ["role": "assistant", "content": "Run this:\n\n```sh\nbin/rails db:upgrade\n```", "has_tool_use": false, "has_tool_result": false],
                ["role": "assistant", "content": "No code here.", "has_tool_use": false, "has_tool_result": false],
            ],
            "total": 4, "first_position": 0, "truncated": false,
        ]) }])

        let messages = try await api.conversation(5, limit: 100).messages

        let blocks = messages.map { MessageSegment.segments(of: $0.content).filter(\.isCode) }
        XCTAssertEqual(blocks[0], [.code("bin/rails test", language: nil)])
        XCTAssertEqual(blocks[1], [.code("12 runs, 0 failures", language: nil)])
        XCTAssertEqual(blocks[2], [.code("bin/rails db:upgrade", language: "sh")])
        XCTAssertEqual(blocks[3], [], "prose alone has nothing to copy")
        XCTAssertFalse(MessageSegment.prose("x").isCode)
    }

    // MARK: - Slash commands

    func testTheSkillsListDecodesWhatTheTypeaheadNeeds() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, ["skills": [
            ["id": "open-pr", "name": "open-pr", "qualified_name": "@local/open-pr", "title": "Open PR",
             "description": "The default PR workflow.", "category": "workflow", "user_invocable": true],
            ["id": "sync-docs", "name": "sync-docs", "title": "Sync Docs", "user_invocable": false],
            ["id": "legacy", "title": "Legacy"],
        ]]) }])

        let skills = try await api.catalog(.skills)

        XCTAssertEqual(transport.sent[0].url.path, "/api/v1/skills")
        XCTAssertEqual(skills.map(\.name), ["open-pr", "sync-docs", nil])
        XCTAssertEqual(skills.map(\.userInvocable), [true, false, nil])
        XCTAssertEqual(skills[0].description, "The default PR workflow.")
    }

    func testTheTypeaheadOffersTheSessionsOwnSkillsAPersonMayInvoke() {
        let catalog = [
            CatalogItem(id: "open-pr", description: "Open the PR.", name: "open-pr", userInvocable: true),
            CatalogItem(id: "wait-for-ci", name: "wait-for-ci", userInvocable: true),
            CatalogItem(id: "sync-docs", name: "sync-docs", userInvocable: false),
            CatalogItem(id: "unsaid", name: "unsaid"),
            CatalogItem(id: "elsewhere", name: "elsewhere", userInvocable: true),
        ]
        var session = SessionSummary(id: 1, status: .needsInput)
        session.catalogSkills = ["wait-for-ci", "open-pr", "sync-docs", "unsaid"]

        XCTAssertEqual(SlashCommand.available(in: catalog, for: session),
                       [SlashCommand(name: "open-pr", description: "Open the PR."), SlashCommand(name: "wait-for-ci")],
                       "chosen for the session and invocable by a person, in the catalog's order")
        session.catalogSkills = nil
        XCTAssertEqual(SlashCommand.available(in: catalog, for: session), [])
    }

    func testASlashIsTypedAtTheStartOfALineOrAfterASpace() {
        XCTAssertEqual(SlashCommand.query(in: "/"), "")
        XCTAssertEqual(SlashCommand.query(in: "/op"), "op")
        XCTAssertEqual(SlashCommand.query(in: "please /wa"), "wa")
        XCTAssertEqual(SlashCommand.query(in: "first line\n/sy"), "sy")
        XCTAssertNil(SlashCommand.query(in: "and/or"), "a slash inside a word is not a command")
        XCTAssertNil(SlashCommand.query(in: "/open-pr now"), "a space after it ends it")
        XCTAssertNil(SlashCommand.query(in: "/a/b"))
        XCTAssertNil(SlashCommand.query(in: ""))
        XCTAssertNil(SlashCommand.query(in: "no command"))
    }

    func testMatchesAreFilteredAndOrderedAsTheWebOrdersThem() {
        let commands = [
            SlashCommand(name: "zimmer-open-issue", description: "File it."),
            SlashCommand(name: "open-pr", description: "Open a PR."),
            SlashCommand(name: "wait-for-ci", description: "Block until CI is done, then open nothing."),
            SlashCommand(name: "op", description: nil),
        ]

        XCTAssertEqual(SlashCommand.matches("", in: commands), commands, "nothing typed: the list as it is")
        XCTAssertEqual(SlashCommand.matches("OP", in: commands).map(\.name), ["op", "open-pr", "wait-for-ci", "zimmer-open-issue"],
                       "names starting with it, shorter first; then the rest, a description match included")
        XCTAssertEqual(SlashCommand.matches("ci", in: commands).map(\.name), ["wait-for-ci"])
        XCTAssertEqual(SlashCommand.matches("nope", in: commands), [])
    }

    func testAChoiceReplacesWhatWasTypedAfterTheSlash() {
        let command = SlashCommand(name: "wait-for-ci")
        XCTAssertEqual(SlashCommand.inserting(command, into: "/wa"), "/wait-for-ci ")
        XCTAssertEqual(SlashCommand.inserting(command, into: "then /"), "then /wait-for-ci ")
        XCTAssertEqual(SlashCommand.inserting(command, into: "no slash"), "no slash", "nothing being typed, nothing replaced")
    }

    func testTheFixtureOffersItsInvocableSkillsOnThePostgresSession() async throws {
        let fake = FakeZimmerAPI()
        let skills = try await fake.catalog(.skills)
        let session = try await fake.session(1035).session
        XCTAssertEqual(SlashCommand.available(in: skills, for: session).map(\.name), ["open-pr", "wait-for-ci"])
    }

    // MARK: - Scheduling class and precedence

    func testTheClassSelectSendsNullToDeriveAndTheClassToChoose() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["session": ["id": 5, "status": "waiting", "scheduling_class": NSNull(), "priority_class": "priority", "genesis": "web_ui"] as [String: Any], "start": ["outcome": "started", "message": "Session 5's next turn is due now."]]) },
            { _ in Fixtures.json(200, ["session": ["id": 5, "status": "running", "scheduling_class": "spot", "priority_class": "spot"]]) },
        ])

        let derived = try await api.setSchedulingClass(5, to: .derive)
        let chosen = try await api.setSchedulingClass(5, to: .spot)

        XCTAssertEqual("\(transport.sent[0].method) \(transport.sent[0].url.path)", "PATCH /api/v1/sessions/5")
        let sent = try body(transport.sent[0])
        XCTAssertTrue(sent["scheduling_class"] is NSNull, "Derive it clears the class: null, as the web select's blank")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(try body(transport.sent[1]) as? [String: String], ["scheduling_class": "spot"], "no placement: the precedence is left as it is")
        XCTAssertNil(derived.session.schedulingClass)
        XCTAssertEqual(derived.session.priorityClass, "priority")
        XCTAssertEqual(derived.startOutcome, "started")
        XCTAssertEqual(chosen.session.schedulingClass, "spot")
    }

    func testTheClassSelectsWordsAndChoiceFollowTheSession() {
        var session = SessionSummary(id: 1, status: .needsInput, priorityClass: "spot", precedence: 5)
        XCTAssertEqual(session.schedulingClassChoice, .derive)
        XCTAssertEqual(SchedulingClassChoice.allCases.map { session.schedulingClassLabel($0) }, ["Derive it (spot)", "Priority", "Spot"])
        XCTAssertEqual(session.precedenceHint, "Higher is worked first — see the Ranked view.")

        session.schedulingClass = "priority"
        session.priorityClass = "priority"
        XCTAssertEqual(session.schedulingClassChoice, .priority)
        XCTAssertEqual(session.schedulingClassLabel(.derive), "Derive it", "the genesis's class is not known while one is chosen")
        XCTAssertEqual(session.precedenceHint, "Unused while this session is priority; it applies if it is demoted to spot.")
    }

    func testAPrecedenceIsAWholeNumberTheServerTakes() async throws {
        XCTAssertEqual(Precedence.parse(" 40 "), 40)
        XCTAssertEqual(Precedence.parse("-3"), -3)
        XCTAssertNil(Precedence.parse("4.5"))
        XCTAssertNil(Precedence.parse(""))
        XCTAssertNil(Precedence.parse("2000000000"))

        let (api, transport) = client([{ _ in Fixtures.json(200, ["session": ["id": 5, "status": "waiting", "precedence": 40]]) }])
        let session = try await api.setPrecedence(5, 40)
        XCTAssertEqual("\(transport.sent[0].method) \(transport.sent[0].url.path)", "PATCH /api/v1/sessions/5")
        XCTAssertEqual(try body(transport.sent[0]) as? [String: Int], ["precedence": 40])
        XCTAssertEqual(session.precedence, 40)
    }

    func testTheFixtureDerivesBackToTheClassItStartedWith() async throws {
        let fake = FakeZimmerAPI()
        let demoted = try await fake.setSchedulingClass(1038, to: .spot)
        XCTAssertEqual(demoted.session.schedulingClass, "spot")
        XCTAssertEqual(demoted.session.priorityClass, "spot")
        let derived = try await fake.setSchedulingClass(1038, to: .derive)
        XCTAssertNil(derived.session.schedulingClass)
        XCTAssertEqual(derived.session.priorityClass, "priority")

        let ranked = try await fake.setPrecedence(1038, 40)
        XCTAssertEqual(ranked.precedence, 40)
        do {
            _ = try await fake.setPrecedence(1038, 2_000_000_000)
            XCTFail("expected a refusal")
        } catch let ZimmerError.http(status, _) {
            XCTAssertEqual(status, 422)
        }
    }
}
