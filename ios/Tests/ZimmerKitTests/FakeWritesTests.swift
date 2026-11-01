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

    func testEveryRefusableWriteIsNamed() {
        XCTAssertTrue(FakeZimmerAPI.refusableWrites.isSuperset(of: ["trash", "follow_up", "quick_router", "visibility"]))
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
