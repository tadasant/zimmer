import XCTest
@testable import ZimmerKit

final class DraftStoreTests: XCTestCase {
    private func store() -> DraftStore {
        let suite = "drafts-\(UUID().uuidString)"
        return DraftStore(defaults: UserDefaults(suiteName: suite)!)
    }

    func testADraftIsKeptPerSessionAndForgottenWhenCleared() {
        let drafts = store()
        drafts.save("Merge it once CI", for: 1038)
        XCTAssertEqual(drafts.draft(for: 1038), "Merge it once CI")
        XCTAssertEqual(drafts.draft(for: 1035), "", "another session has its own")
        drafts.save("   ", for: 1038)
        XCTAssertEqual(drafts.draft(for: 1038), "")
    }

    func testADraftOlderThanSevenDaysIsGone() {
        let drafts = store()
        let then = Date(timeIntervalSince1970: 1_000_000)
        drafts.save("old words", for: 7, now: then)
        XCTAssertEqual(drafts.draft(for: 7, now: then.addingTimeInterval(6 * 24 * 3600)), "old words")
        XCTAssertEqual(drafts.draft(for: 7, now: then.addingTimeInterval(8 * 24 * 3600)), "")
    }
}
