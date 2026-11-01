import XCTest
@testable import ZimmerKit

/// The fixture's writes can be refused and slowed, so a screen can be seen showing an action at
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

    func testAWriteDelayHoldsTheAnswer() async throws {
        let api = FakeZimmerAPI(writeDelay: .milliseconds(300))
        let started = Date()
        _ = try await api.setVisibility(1038, .hidden)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
        let read = Date()
        _ = try await api.session(1038)
        XCTAssertLessThan(Date().timeIntervalSince(read), 0.25, "reads are not held")
    }
}
