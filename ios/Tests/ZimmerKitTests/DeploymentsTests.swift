import XCTest
@testable import ZimmerKit

final class DeploymentsTests: XCTestCase {
    private let alpha = ServerOrigins(web: URL(string: "https://alpha.example.com")!)
    private let beta = ServerOrigins(web: URL(string: "https://beta.example.org")!, api: URL(string: "https://beta-app.example.org")!)
    private let gamma = ServerOrigins(web: URL(string: "https://www.gamma.example.net")!)

    private func signIn(_ origins: ServerOrigins) -> StoredSignIn {
        StoredSignIn(origins: origins, tokens: OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture))
    }

    // MARK: - Migration

    func testAnExistingSignInBecomesTheFirstDeploymentUnderItsOldStorageNames() {
        let store = InMemoryDeploymentStore()
        let list = DeploymentList.load(from: store) { self.signIn(self.beta) }

        XCTAssertEqual(list.deployments.count, 1)
        let migrated = try! XCTUnwrap(list.active)
        XCTAssertEqual(migrated.id, Deployment.migratedID)
        XCTAssertEqual(migrated.origins, beta, "both origins carry over, so the edge login keeps working")
        // Nothing moves: the Keychain items and UserDefaults keys the single-deployment app wrote.
        XCTAssertEqual(migrated.signInAccount, "zimmer.sign-in")
        XCTAssertEqual(migrated.edgeAccount, "zimmer.edge-access-token")
        XCTAssertEqual(migrated.defaultsKey("boardFilters"), "boardFilters")
        XCTAssertEqual(migrated.defaultsKey("draft.") + "12", "draft.12")
        XCTAssertEqual(store.load(), list, "saved, so it is migrated once")
    }

    func testTheMigrationReadsTheOldSignInOnlyWhenNothingIsStored() {
        let stored = DeploymentList([Deployment(id: "x", origins: alpha)])
        var read = false
        let list = DeploymentList.load(from: InMemoryDeploymentStore(stored)) { read = true; return self.signIn(self.beta) }
        XCTAssertEqual(list, stored)
        XCTAssertFalse(read)
    }

    func testAnUnreadableOldSignInIsNotSavedAsNoDeploymentsSoTheMigrationIsTriedAgain() {
        let store = InMemoryDeploymentStore()
        XCTAssertTrue(DeploymentList.load(from: store) { nil }.isEmpty)
        XCTAssertNil(store.load())
        XCTAssertEqual(DeploymentList.load(from: store) { self.signIn(self.alpha) }.deployments.map(\.id), [Deployment.migratedID])
    }

    func testTheListSurvivesUserDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DeploymentsTests.\(UUID())"))
        let store = UserDefaultsDeploymentStore(defaults: defaults)
        var list = DeploymentList([Deployment(id: "a", origins: alpha)])
        list.add(Deployment(id: "b", name: "Beta", origins: beta))
        store.save(list)
        XCTAssertEqual(store.load(), list)
        XCTAssertEqual(store.load()?.activeID, "b")
    }

    // MARK: - Isolation

    func testEveryOtherDeploymentKeepsItsStateUnderKeysOfItsOwn() {
        let one = Deployment(id: "one", origins: alpha)
        let two = Deployment(id: "two", origins: alpha)
        XCTAssertNotEqual(one.signInAccount, two.signInAccount)
        XCTAssertNotEqual(one.edgeAccount, two.edgeAccount)
        XCTAssertNotEqual(one.defaultsKey("boardFilters"), two.defaultsKey("boardFilters"))
        let migrated = Deployment(id: Deployment.migratedID, origins: alpha)
        for key in [one.signInAccount, one.edgeAccount, one.defaultsKey("draft.")] {
            XCTAssertFalse([migrated.signInAccount, migrated.edgeAccount, "draft."].contains(key))
        }
        XCTAssertFalse(one.defaultsKey("draft.3").hasPrefix("draft."), "the migrated deployment's drafts are told apart by their prefix")
    }

    func testDraftsOnTwoDeploymentsNeverMeetForTheSameSessionID() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DeploymentsTests.\(UUID())"))
        let mine = DraftStore(defaults: defaults, prefix: Deployment(id: Deployment.migratedID, origins: alpha).defaultsKey("draft."))
        let theirs = DraftStore(defaults: defaults, prefix: Deployment(id: "lab", origins: beta).defaultsKey("draft."))
        mine.save("merge it", for: 42)
        XCTAssertEqual(theirs.draft(for: 42), "")
        theirs.save("hold off", for: 42)
        XCTAssertEqual(mine.draft(for: 42), "merge it")
    }

    func testRemovingADeploymentForgetsOnlyItsOwnDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DeploymentsTests.\(UUID())"))
        let migrated = Deployment(id: Deployment.migratedID, origins: alpha)
        let lab = Deployment(id: "lab", origins: beta)
        defaults.set("x", forKey: "draft.1")
        defaults.set("x", forKey: "boardView")
        defaults.set("x", forKey: lab.defaultsKey("draft.1"))
        defaults.set("x", forKey: lab.defaultsKey("boardView"))
        defaults.set("x", forKey: UserDefaultsDeploymentStore.key)

        UserDefaultsDeploymentStore.forgetDefaults(of: lab, in: defaults, legacyKeys: ["boardView"])
        XCTAssertNil(defaults.object(forKey: lab.defaultsKey("draft.1")))
        XCTAssertNil(defaults.object(forKey: lab.defaultsKey("boardView")))
        XCTAssertNotNil(defaults.object(forKey: "draft.1"))
        XCTAssertNotNil(defaults.object(forKey: "boardView"))

        defaults.set("x", forKey: lab.defaultsKey("draft.1"))
        UserDefaultsDeploymentStore.forgetDefaults(of: migrated, in: defaults, legacyKeys: ["boardView"])
        XCTAssertNil(defaults.object(forKey: "draft.1"))
        XCTAssertNil(defaults.object(forKey: "boardView"))
        XCTAssertNotNil(defaults.object(forKey: lab.defaultsKey("draft.1")), "another deployment's draft is not the migrated one's")
        XCTAssertNotNil(defaults.object(forKey: UserDefaultsDeploymentStore.key), "the list itself stays")
    }

    // MARK: - The list

    func testAddingPutsTheNewDeploymentAtTheEndAndInFront() {
        var list = DeploymentList([Deployment(id: "a", origins: alpha)])
        list.add(Deployment(id: "b", origins: beta))
        XCTAssertEqual(list.deployments.map(\.id), ["a", "b"])
        XCTAssertEqual(list.activeID, "b")
        XCTAssertEqual(list.existing(for: ServerOrigins(web: URL(string: "https://alpha.example.com")!))?.id, "a")
        XCTAssertNil(list.existing(for: gamma))
    }

    func testRemovingTheOneInFrontBringsItsNeighbourForward() {
        var list = DeploymentList(["a", "b", "c"].map { Deployment(id: $0, origins: alpha) }, activeID: "b")
        list.remove("b")
        XCTAssertEqual(list.activeID, "c", "the next one")
        list.remove("c")
        XCTAssertEqual(list.activeID, "a", "the previous one, at the end of the list")
        list.remove("a")
        XCTAssertNil(list.activeID)
        XCTAssertTrue(list.isEmpty)
    }

    func testRemovingOneBehindLeavesTheOneInFront() {
        var list = DeploymentList(["a", "b"].map { Deployment(id: $0, origins: alpha) }, activeID: "b")
        XCTAssertEqual(list.remove("a")?.id, "a")
        XCTAssertEqual(list.activeID, "b")
        XCTAssertNil(list.remove("nope"))
    }

    func testActivatingNeedsADeploymentOnTheList() {
        var list = DeploymentList(["a", "b"].map { Deployment(id: $0, origins: alpha) })
        XCTAssertEqual(list.activeID, "a", "the first is in front when none was saved")
        XCTAssertFalse(list.activate("z"))
        XCTAssertTrue(list.activate("b"))
        XCTAssertEqual(list.active?.id, "b")
        XCTAssertEqual(DeploymentList([Deployment(id: "a", origins: alpha)], activeID: "gone").activeID, "a")
    }

    func testMovingFollowsListOnMove() {
        var list = DeploymentList(["a", "b", "c", "d"].map { Deployment(id: $0, origins: alpha) })
        list.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(list.deployments.map(\.id), ["b", "c", "a", "d"])
        list.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(list.deployments.map(\.id), ["d", "b", "c", "a"])
        list.move(fromOffsets: IndexSet([1, 2]), toOffset: 4)
        XCTAssertEqual(list.deployments.map(\.id), ["d", "a", "b", "c"])
    }

    func testNamesStartAsTheHostAndRenamingEmptyPutsItBack() {
        XCTAssertEqual(Deployment(origins: alpha).name, "alpha.example.com")
        XCTAssertEqual(Deployment(origins: gamma).name, "gamma.example.net")
        var list = DeploymentList([Deployment(id: "a", origins: alpha)])
        list.rename("a", to: "  Workshop ")
        XCTAssertEqual(list.active?.name, "Workshop")
        list.rename("a", to: "   ")
        XCTAssertEqual(list.active?.name, "alpha.example.com")
    }

    func testInitialsAndColourAreStable() {
        XCTAssertEqual(Deployment(name: "Workshop", origins: alpha).initials, "W")
        XCTAssertEqual(Deployment(origins: alpha).initials, "AE")
        XCTAssertEqual(Deployment(name: "my lab", origins: alpha).initials, "ML")
        let one = Deployment(id: "fixed-id", origins: alpha)
        XCTAssertEqual(one.paletteIndex(count: 8), Deployment(id: "fixed-id", origins: beta).paletteIndex(count: 8))
        XCTAssertTrue((0..<8).contains(one.paletteIndex(count: 8)))
        XCTAssertEqual(one.paletteIndex(count: 0), 0)
    }

    // MARK: - Pushes

    func testThePushTagIsTheServersOwnDigestOfItsHost() {
        // The same value `test/services/apns_service_test.rb` holds the server to.
        XCTAssertEqual(Deployment.pushTag(host: "zimmer.example.com"), "90662b17ebf2df11")
        XCTAssertEqual(Deployment.pushTag(host: "Zimmer.Example.COM"), "90662b17ebf2df11")
        XCTAssertEqual(Deployment.pushTag(host: "alpha.example.com"), "519b98ecd24f522b")
    }

    func testAPushOpensOnTheDeploymentThatSentIt() {
        let a = Deployment(id: "a", origins: alpha)
        let b = Deployment(id: "b", origins: beta)
        let list = DeploymentList([a, b], activeID: "a")
        XCTAssertEqual(list.route(forPush: "519b98ecd24f522b"), .active)
        XCTAssertEqual(list.route(forPush: Deployment.pushTag(host: "beta.example.org")), .other(b))
        XCTAssertEqual(list.route(forPush: Deployment.pushTag(host: "beta-app.example.org")), .other(b), "either origin names it")
        XCTAssertEqual(list.route(forPush: Deployment.pushTag(host: "elsewhere.example.com")), .unknown)
    }

    func testAPushThatDoesNotSayWhereItCameFromOpensOnlyWhenOneDeploymentCouldHaveSentIt() {
        let one = DeploymentList([Deployment(id: "a", origins: alpha)])
        XCTAssertEqual(one.route(forPush: nil), .active)
        let two = DeploymentList([Deployment(id: "a", origins: alpha), Deployment(id: "b", origins: beta)])
        XCTAssertEqual(two.route(forPush: nil), .unknown)
        XCTAssertEqual(DeploymentList().route(forPush: "519b98ecd24f522b"), .unknown)
    }

    func testThePushPayloadCarriesItsSendersTag() {
        XCTAssertEqual(PushPayload(userInfo: ["session_id": 5, "deployment": "519B98ECD24F522B"]).deployment, "519b98ecd24f522b")
        XCTAssertNil(PushPayload(userInfo: ["session_id": 5]).deployment)
        XCTAssertNil(PushPayload(userInfo: ["session_id": 5, "deployment": ""]).deployment)
    }
}
