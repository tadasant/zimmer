import XCTest
@testable import ZimmerKit

/// The fixture's writes can be refused and held, so a screen can be seen showing an action at
/// the tap and putting it back on a refusal.
final class FakeWritesTests: XCTestCase {
    func testARefusedWriteThrowsAndChangesNothing() async throws {
        let api = FakeZimmerAPI(refuses: ["trash"])
        do {
            _ = try await api.trash(1038, force: false)
            XCTFail("the fixture was told to refuse the trash")
        } catch let ZimmerError.http(status, message) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(message, "The fixture refused this trash, to show it being put back.")
        }
        let session = try await api.session(1038).session
        XCTAssertEqual(session.status, .needsInput, "a refused write leaves the session as it was")
        _ = try await api.setVisibility(1038, .hidden)
    }

    /// Each name in `refusableWrites` is consulted by the write it names, so a UI test can
    /// refuse any of them — and none is listed that nothing consults.
    func testEveryRefusableWriteIsConsulted() async {
        let writes: [String: (FakeZimmerAPI) async throws -> Void] = [
            "follow_up": { _ = try await $0.followUp(1038, prompt: "Go ahead.") },
            "trash": { _ = try await $0.trash(1038, force: false) },
            "unarchive": { _ = try await $0.unarchive(1019) },
            "visibility": { _ = try await $0.setVisibility(1038, .hidden) },
            "quick_router": { _ = try await $0.startQuickRouter(QuickRouterRequest(prompt: "Rotate the key")) },
            "create_session": { _ = try await $0.createSession(NewSessionRequest(agentRoot: "zimmer", prompt: "Fix it")) },
            "elicitation": { try await $0.answerElicitation(1, answer: .decline, content: nil) },
            "notification": { try await $0.markAllNotificationsRead() },
            "trigger": { _ = try await $0.toggleTrigger(5) },
            "fork": { _ = try await $0.fork(1038, at: 0) },
            "restart": { _ = try await $0.restart(1027) },
            "pause": { _ = try await $0.pause(1042) },
            "notes": { _ = try await $0.updateNotes(1038, notes: "Note") },
            "rename": { _ = try await $0.rename(1038, title: "Renamed") },
            "goal": { _ = try await $0.updateGoal(1038, goal: "Ship") },
            "effort": { _ = try await $0.updateEffort(1038, effort: nil) },
            "scheduling_class": { _ = try await $0.setSchedulingClass(1038, priority: true) },
            "precedence": { _ = try await $0.setPrecedence(1038, 3) },
            "heartbeat": { _ = try await $0.setHeartbeat(1038, enabled: true) },
            "bulk_archive": { _ = try await $0.bulkArchive([1038]) },
            "reorder": { _ = try await $0.reorder(1031, above: nil, below: nil) },
            "queue": { try await $0.deleteQueued(1042, message: 1) },
            "model": { _ = try await $0.updateModel(1038, model: "claude-opus-5-5") },
            "catalog": { _ = try await $0.updateSelection(1038, .skills, to: []) },
            "board_category": { _ = try await $0.assignBoardCategory(1038, categoryID: 1) },
        ]
        XCTAssertEqual(Set(writes.keys), FakeZimmerAPI.refusableWrites, "every refusable write has a call here, and nothing else is listed")
        for (name, write) in writes {
            let api = FakeZimmerAPI(refuses: [name])
            do {
                try await write(api)
                XCTFail("\(name) was not refused")
            } catch let ZimmerError.http(status, _) {
                XCTAssertEqual(status, 503, name)
            } catch {
                XCTFail("\(name) failed for another reason: \(error)")
            }
        }
    }

    /// A held write is asked, and stays unanswered for as long as nobody lets it go.
    func testAHeldWriteIsAnsweredOnlyOnceItIsLetGo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let api = FakeZimmerAPI(hold: FixtureHold(["visibility"], in: directory))
        let held = directory.appendingPathComponent("visibility.held").path
        let write = Task { try await api.setVisibility(1038, .hidden) }
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: held) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: held), "the write was asked")
        try await Task.sleep(for: .milliseconds(300))
        // Reads, and a write that is not held, go past it; it has changed nothing.
        _ = try await api.rename(1038, title: "Renamed")
        let waiting = try await api.session(1038).session
        XCTAssertNotEqual(waiting.visibility, .hidden, "the held write is not taken")

        try Data().write(to: directory.appendingPathComponent("visibility.answer"))
        _ = try await write.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: held), "nothing is held now")
        let taken = try await api.session(1038).session
        XCTAssertEqual(taken.visibility, .hidden, "let go, it is")
        // Let go is let go: the same write again is not held.
        _ = try await api.setVisibility(1038, .visible)
    }

    func testOpeningASessionIsHeldAndReadingItAgainIsNot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let api = FakeZimmerAPI(hold: FixtureHold([FixtureHold.openSession], in: directory))
        let opening = Task { try await api.openSession(1038) }
        _ = try await api.session(1038)
        // A page left while it loads stops asking, as a request to a server does.
        opening.cancel()
        do {
            _ = try await opening.value
            XCTFail("a held read was answered though nobody let it go")
        } catch is CancellationError {}

        let asked = Task { try await api.openSession(1038) }
        try Data().write(to: directory.appendingPathComponent("open_session.answer"))
        let opened = try await asked.value.session
        XCTAssertEqual(opened.id, 1038)
    }
}
