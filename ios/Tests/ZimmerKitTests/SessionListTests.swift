import XCTest
@testable import ZimmerKit

final class SessionListTests: XCTestCase {
    func testOrderingPutsNeedsInputFirstThenNewest() {
        let now = Date()
        let sessions = [
            SessionSummary(id: 1, status: .running, updatedAt: now),
            SessionSummary(id: 2, status: .needsInput, updatedAt: now.addingTimeInterval(-600)),
            SessionSummary(id: 3, status: .needsInput, updatedAt: now.addingTimeInterval(-60)),
            SessionSummary(id: 4, status: .failed, updatedAt: now.addingTimeInterval(-6000)),
            SessionSummary(id: 5, status: .waiting),
        ]
        XCTAssertEqual(SessionOrdering.sorted(sessions).map(\.id), [3, 2, 4, 1, 5])
    }

    func testFiltersAskTheServerForTheRightRows() {
        XCTAssertEqual(SessionFilter.needsInput.query["status"], "needs_input")
        XCTAssertNil(SessionFilter.active.query["status"])
        XCTAssertNil(SessionFilter.active.query["show_archived"])
        XCTAssertEqual(SessionFilter.archived.query["status"], "archived")
        XCTAssertEqual(SessionFilter.archived.query["show_archived"], "true")
        XCTAssertEqual(SessionFilter.allCases.first, .needsInput)
    }

    func testTheFakeBehavesLikeTheServerOnFilters() async throws {
        let fake = FakeZimmerAPI()
        let needsInput = try await fake.sessions(.needsInput)
        let active = try await fake.sessions(.active)
        let archived = try await fake.sessions(.archived)

        XCTAssertFalse(needsInput.isEmpty)
        XCTAssertTrue(needsInput.allSatisfy { $0.status == .needsInput })
        XCTAssertFalse(active.contains { $0.status == .archived })
        XCTAssertEqual(active.first?.status, .needsInput)
        XCTAssertTrue(archived.allSatisfy { $0.status == .archived })
    }

    func testServerURLsMustBeHttpsOrigins() {
        XCTAssertEqual(ServerURL.parse(" https://Zimmer.Example.test/ ")?.absoluteString, "https://zimmer.example.test")
        XCTAssertEqual(ServerURL.parse("https://zimmer.example.test:8443")?.absoluteString, "https://zimmer.example.test:8443")
        XCTAssertNil(ServerURL.parse("http://zimmer.example.test"))
        XCTAssertNil(ServerURL.parse("https://zimmer.example.test/sessions"))
        XCTAssertNil(ServerURL.parse("https://user:pw@zimmer.example.test"))
        XCTAssertNil(ServerURL.parse(""))
        XCTAssertNil(ServerURL.parse("zimmer.example.test"))
    }

    func testBuildEnvironmentDefaultsToProduction() {
        XCTAssertEqual(BuildEnvironment(label: nil), .production)
        XCTAssertEqual(BuildEnvironment(label: "Staging"), .staging)
        XCTAssertNil(BuildEnvironment.production.badge)
    }

    func testPathComponentsEscapeEverythingButUnreservedASCII() {
        XCTAssertEqual(ZimmerPathComponent("café/1?x").description, "caf%C3%A9%2F1%3Fx")
        XCTAssertEqual(ZimmerPathComponent("my-slug_1.2~").description, "my-slug_1.2~")
    }
}
