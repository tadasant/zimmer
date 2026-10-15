import XCTest
@testable import ZimmerKit

/// The auth boundary: who the token is, the deployment's connections and keys, and the writes
/// on them.
final class AccountTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private static func me() -> [String: Any] {
        [
            "me": ["authenticated_as": "native_app", "email": "tadas@example.com", "privilege": "act_as_human", "acts_as_you": true, "grant_id": 7, "api_key": NSNull()],
            "web_sign_in": ["email": "tadas@example.com", "name": "Tadas", "last_signed_in_at": "2026-10-14T09:00:00Z", "totp_required": true,
                            "totp_enrolled_at": "2026-09-25T12:00:00.123Z", "recovery_codes_remaining": 8],
            "deployment": ["git": ["commit_sha": "b7d4e1c9a0f2d3e4c5b6a7980f1e2d3c4b5a6978", "commit_short": "b7d4e1c", "branch": "main", "commit_date": "2026-10-14 17:22:05 +0000"],
                           "environment": ["rails_env": "production", "ruby_version": "3.4.6", "rails_version": "8.1.0"]],
        ]
    }

    private static func grant(id: Int, current: Bool, privilege: String = "act_as_human", status: String = "active") -> [String: Any] {
        ["id": id, "client_name": "Zimmer iOS", "client_label": "Zimmer iOS", "client_id": "zimmer-native-app", "first_party": true,
         "registration": "self_registered", "publisher_host": NSNull(), "user_email": "tadas@example.com", "privilege": privilege,
         "acts_as_you": privilege == "act_as_human", "status": status, "current": current, "created_at": "2026-10-01T10:00:00Z",
         "last_used_at": "2026-10-15T08:00:00Z", "scope_changed_at": "2026-10-01T10:00:00Z", "scope_change_reason": "consent",
         "revoked_at": NSNull(), "revocation_reason": NSNull()]
    }

    private static func key(id: Int, name: String, source: String = "minted", status: String = "active", selfSession: Bool = false) -> [String: Any] {
        ["id": id, "name": name, "status": status, "source": source, "grant": "api", "fingerprint": "9a1b2c3d", "external_app": NSNull(),
         "agent_sessions_use_it": selfSession, "last_used_at": NSNull(), "created_at": "2026-10-06T10:00:00Z", "revoked_at": NSNull()]
    }

    func testMeDecodesWithTheCardAndTheDeployment() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, Self.me()) }])

        let account = try await api.account()

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, ["GET /api/v1/me"])
        XCTAssertEqual(account.me.email, "tadas@example.com")
        XCTAssertTrue(account.me.actsAsYou)
        XCTAssertEqual(account.me.grantID, 7)
        XCTAssertNil(account.me.apiKey)
        XCTAssertEqual(account.me.privilegeLabel, "Acts on your behalf")
        let card = try XCTUnwrap(account.webSignIn)
        XCTAssertNotNil(card.totpEnrolledAt, "fractional seconds decode")
        XCTAssertEqual(card.recoveryCodesLine, "8 recovery codes left")
        XCTAssertEqual(account.deployment.git.commitShort, "b7d4e1c")
        XCTAssertEqual(account.deployment.git.commitDate, "2026-10-14 17:22:05 +0000")
        XCTAssertEqual(account.deployment.environment.railsEnv, "production")

        let data = try JSONEncoder().encode(account)
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: data), account, "the answer survives a round trip")
    }

    /// `/me` with the card withheld: on a relay-only grant, and on an API key.
    private static func relayMe() -> [String: Any] {
        var relay = me()
        relay["me"] = ["authenticated_as": "native_app", "email": "tadas@example.com", "privilege": "relay_only", "acts_as_you": false, "grant_id": 7, "api_key": NSNull()]
        relay["web_sign_in"] = NSNull()
        return relay
    }

    private static func keyedMe() -> [String: Any] {
        var keyed = me()
        keyed["me"] = ["authenticated_as": "api_key", "email": NSNull(), "privilege": NSNull(), "acts_as_you": false, "grant_id": NSNull(),
                       "api_key": ["id": 2, "name": "laptop scripts", "source": "minted", "grant": "api"]]
        keyed["web_sign_in"] = NSNull()
        return keyed
    }

    func testMeOnAnAPIKeyOrARelayGrantHasNoCard() async throws {
        let (api, _) = client([{ _ in Fixtures.json(200, Self.relayMe()) }, { _ in Fixtures.json(200, Self.keyedMe()) }])

        let onRelay = try await api.account()
        XCTAssertNil(onRelay.webSignIn)
        XCTAssertEqual(onRelay.me.privilegeLabel, "Relay only")
        let onKey = try await api.account()
        XCTAssertNil(onKey.me.email)
        XCTAssertEqual(onKey.me.apiKey?.name, "laptop scripts")
        XCTAssertNil(Account.WebSignIn(email: "x", totpRequired: true).recoveryCodesLine, "no line until an authenticator stands")
        XCTAssertEqual(Account.WebSignIn(email: "x", totpRequired: true, totpEnrolledAt: Date(), recoveryCodesRemaining: 1).recoveryCodesLine, "1 recovery code left")
    }

    func testTheConnectionsListAndItsTwoWrites() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["oauth_grants": [Self.grant(id: 7, current: true), Self.grant(id: 4, current: false, privilege: "relay_only")]]) },
            { _ in Fixtures.json(200, ["oauth_grant": Self.grant(id: 4, current: false, privilege: "act_as_human"), "message": "Zimmer iOS now acts on your behalf"]) },
            { _ in Fixtures.json(200, ["oauth_grant": Self.grant(id: 4, current: false, status: "revoked"), "signed_out": false, "message": "Revoked Zimmer iOS's connection."]) },
            { _ in Fixtures.json(200, ["oauth_grant": Self.grant(id: 7, current: true, status: "revoked"), "signed_out": true, "message": "Revoked."]) },
        ])

        let grants = try await api.oauthGrants()
        XCTAssertEqual(grants.map(\.id), [7, 4])
        XCTAssertEqual(grants.map(\.current), [true, false])
        XCTAssertEqual(grants[1].privilegeLabel, "Relay only")
        XCTAssertEqual(grants[1].registrationLabel, "Self-registered")
        XCTAssertEqual(grants[1].scopeChangeLabel, "chosen at approval")

        let raised = try await api.setGrantPrivilege(4, actsAsYou: true)
        XCTAssertTrue(raised.actsAsYou)
        let other = try await api.revokeGrant(4)
        XCTAssertFalse(other.signedOut)
        XCTAssertTrue(other.grant.isRevoked)
        let own = try await api.revokeGrant(7)
        XCTAssertTrue(own.signedOut, "revoking this phone's connection is a sign-out")

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" },
                       ["GET /api/v1/oauth_grants", "PATCH /api/v1/oauth_grants/4", "DELETE /api/v1/oauth_grants/4", "DELETE /api/v1/oauth_grants/7"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[1].body ?? Data()) as? [String: String])
        XCTAssertEqual(body, ["privilege": "act_as_human"])
    }

    func testTheKeysListMintRevokeRestoreAndSignOutEverywhere() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["api_keys": [Self.key(id: 1, name: "c0ffee42", source: "env", selfSession: true), Self.key(id: 2, name: "laptop scripts")]]) },
            { _ in Fixtures.json(201, ["api_key": Self.key(id: 3, name: "phone"), "token": "zmr_once"]) },
            { _ in Fixtures.json(200, ["api_key": Self.key(id: 3, name: "phone", status: "revoked"), "message": "Revoked phone."]) },
            { _ in Fixtures.json(200, ["api_key": Self.key(id: 3, name: "phone"), "message": "Restored phone."]) },
            { _ in Fixtures.json(200, ["signed_out_everywhere": true, "web_sign_ins_ended": 2, "this_connection_revoked": true, "message": "Signed out on every device."]) },
        ])

        let keys = try await api.apiKeys()
        XCTAssertEqual(keys.map(\.sourceLabel), ["ZIMMER_API_KEYS", "Minted"])
        XCTAssertTrue(keys[0].agentSessionsUseIt)
        XCTAssertTrue(keys[0].revokeConfirmation.contains("Every agent session uses this key"))
        XCTAssertTrue(keys[1].revokeConfirmation.hasPrefix("Revoke laptop scripts? Requests carrying it"))

        let minted = try await api.mintAPIKey(name: "phone", grant: "api")
        XCTAssertEqual(minted.token, "zmr_once")
        XCTAssertEqual(minted.key.name, "phone")
        let revoked = try await api.revokeAPIKey(3)
        XCTAssertEqual(revoked.statusLabel, "Revoked")
        let restored = try await api.restoreAPIKey(3)
        XCTAssertEqual(restored.statusLabel, "Active")
        let out = try await api.signOutEverywhere()
        XCTAssertEqual(out.webSignInsEnded, 2)
        XCTAssertTrue(out.thisConnectionRevoked)

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" },
                       ["GET /api/v1/api_keys", "POST /api/v1/api_keys", "DELETE /api/v1/api_keys/3", "POST /api/v1/api_keys/3/restore", "POST /api/v1/sign_out_everywhere"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[1].body ?? Data()) as? [String: String])
        XCTAssertEqual(body, ["name": "phone", "grant": "api"])
    }

    func testARefusalCarriesTheServersMessage() async throws {
        let (api, _) = client([
            { _ in Fixtures.json(403, ["error": "Forbidden", "message": FakeZimmerAPI.relayOnlyWriteRefusal]) },
            { _ in Fixtures.json(422, ["error": "Key not created", "message": "Name has already been taken"]) },
        ])

        do {
            _ = try await api.revokeGrant(4)
            XCTFail("a relay-only grant is refused")
        } catch let error as ZimmerError {
            XCTAssertEqual(error, .http(status: 403, message: FakeZimmerAPI.relayOnlyWriteRefusal))
        }
        do {
            _ = try await api.mintAPIKey(name: "laptop scripts", grant: "api")
            XCTFail("a taken name is refused")
        } catch let error as ZimmerError {
            XCTAssertEqual(error, .http(status: 422, message: "Name has already been taken"))
        }
    }

    func testTheFixtureListsThisPhoneAndAnotherAndAnswersWritesAsTheServerDoes() async throws {
        let fake = FakeZimmerAPI()
        let account = try await fake.account()
        XCTAssertTrue(account.me.actsAsYou)
        XCTAssertEqual(account.me.grantID, FakeZimmerAPI.ownGrantID)
        XCTAssertEqual(account.webSignIn?.recoveryCodesLine, "8 recovery codes left")

        let grants = try await fake.oauthGrants()
        XCTAssertEqual(grants.map(\.current), [true, false], "this phone first: most recently used")
        XCTAssertEqual(grants.map(\.actsAsYou), [true, false])

        // Re-level the other phone, then revoke it: the row stays, marked revoked, and cannot be re-levelled.
        let raised = try await fake.setGrantPrivilege(4, actsAsYou: true)
        XCTAssertTrue(raised.actsAsYou)
        let afterRaise = try await fake.oauthGrants()
        XCTAssertEqual(afterRaise[1].scopeChangeLabel, "raised from the iOS app")
        let revoked = try await fake.revokeGrant(4)
        XCTAssertFalse(revoked.signedOut)
        let afterRevoke = try await fake.oauthGrants()
        XCTAssertEqual(afterRevoke.map(\.isRevoked), [false, true])
        await XCTAssertThrowsAsync(try await fake.setGrantPrivilege(4, actsAsYou: false), "a revoked connection has to be approved again")

        // Keys: the env one is marked, a mint answers a token whose fingerprint matches the row,
        // a taken name is refused, revoke keeps the row and restore undoes it.
        let keys = try await fake.apiKeys()
        XCTAssertEqual(keys.map(\.name), ["laptop scripts", "c0ffee42"], "newest first")
        XCTAssertTrue(keys[1].agentSessionsUseIt)
        let minted = try await fake.mintAPIKey(name: "phone", grant: "quick_router")
        XCTAssertTrue(minted.token.hasPrefix("zmr_"))
        XCTAssertEqual(minted.key.fingerprint, FakeZimmerAPI.fingerprint(minted.token))
        XCTAssertTrue(minted.key.isQuickRouter)
        let afterMint = try await fake.apiKeys()
        XCTAssertEqual(afterMint.first?.id, minted.key.id, "the minted key heads the list")
        await XCTAssertThrowsAsync(try await fake.mintAPIKey(name: "phone", grant: "api"), "a taken name")
        await XCTAssertThrowsAsync(try await fake.mintAPIKey(name: " ", grant: "api"), "a blank name")
        await XCTAssertThrowsAsync(try await fake.mintAPIKey(name: "ext", grant: "external_app"), "a grant a person may not mint")
        let revokedKey = try await fake.revokeAPIKey(minted.key.id)
        XCTAssertTrue(revokedKey.isRevoked)
        let afterKeyRevoke = try await fake.apiKeys()
        XCTAssertEqual(afterKeyRevoke.last?.id, minted.key.id, "revoked keys sink to the end")
        let restoredKey = try await fake.restoreAPIKey(minted.key.id)
        XCTAssertEqual(restoredKey.statusLabel, "Active")

        // Signing out everywhere revokes this phone's own connection.
        let out = try await fake.signOutEverywhere()
        XCTAssertTrue(out.thisConnectionRevoked)
        let afterSignOut = try await fake.oauthGrants()
        XCTAssertEqual(afterSignOut.first { $0.current }?.isRevoked, true)
    }

    func testARelayOnlyFixtureReadsButIsRefusedEveryWrite() async throws {
        let fake = FakeZimmerAPI(relayOnly: true)
        let account = try await fake.account()
        XCTAssertFalse(account.me.actsAsYou)
        XCTAssertNil(account.webSignIn, "the card goes only to a sign-in acting as you")
        let grants = try await fake.oauthGrants()
        XCTAssertEqual(grants.first?.privilegeLabel, "Relay only")

        for write: () async throws -> Void in [
            { _ = try await fake.revokeGrant(4) },
            { _ = try await fake.setGrantPrivilege(7, actsAsYou: true) },
            { _ = try await fake.mintAPIKey(name: "phone", grant: "api") },
            { _ = try await fake.revokeAPIKey(2) },
            { _ = try await fake.restoreAPIKey(2) },
            { _ = try await fake.signOutEverywhere() },
        ] {
            do {
                try await write()
                XCTFail("a relay-only grant is refused every write")
            } catch let error as ZimmerError {
                XCTAssertEqual(error, .http(status: 403, message: FakeZimmerAPI.relayOnlyWriteRefusal))
            }
        }
        let grantsAfter = try await fake.oauthGrants()
        XCTAssertEqual(grantsAfter.map(\.isRevoked), [false, false], "refused before anything is stored")
        let keysAfter = try await fake.apiKeys()
        XCTAssertEqual(keysAfter.map(\.isRevoked), [false, false])
    }
}
