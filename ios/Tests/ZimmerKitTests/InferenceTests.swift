import XCTest
@testable import ZimmerKit

/// The Inference page: the report decodes as the server renders it, every write hits its
/// route with the parameter names the server takes, and the fake behaves like the server.
final class InferenceTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
    }

    /// A function, not a stored value: `[String: Any]` is not Sendable, and a test's handler runs on another task.
    private static func report() -> [String: Any] {
        [
        "runtime": "claude_code",
        "runtimes": [["key": "claude_code", "label": "Claude Code"], ["key": "codex", "label": "Codex"], ["key": "pi", "label": "Pi"]],
        "accounts": [[
            "id": 11, "email": "ops@tadasant.com", "runtime": "claude_code", "priority": 0, "is_current": true, "status": "active",
            "effective_status": "quota_exceeded", "quota_hit_count": 2, "api_key_account": false,
            "credentials": ["state": "verified", "stored": true, "refused": false, "rejected_at": NSNull(), "rejection_reason": NSNull(), "verified_at": "2026-10-13T01:00:00Z"],
            "probe_error": NSNull(),
            "quota": [
                "taken_at": "2026-10-16T01:00:00Z", "trigger": "manual_refresh", "subscription_type": "max", "rate_limit_tier": "default_claude_max_20x",
                "five_hour": ["utilization": 0.42, "effective_utilization": 0.42, "status": "allowed", "reset_at": "2026-10-16T03:10:00Z", "reset_passed": false],
                "seven_day": ["utilization": 1.0, "effective_utilization": 0, "status": NSNull(), "reset_at": "2026-10-15T00:00:00Z", "reset_passed": true],
                "five_hour_headroom_unusable": false,
            ],
            "login": ["available": true,
                      "active_attempt": ["id": 301, "account_id": 11, "runtime": "claude_code", "status": "awaiting_code", "terminal": false,
                                         "verification_url": NSNull(), "verification_code": NSNull(), "awaiting_code": true, "code_received": false,
                                         "error_message": NSNull(), "expires_at": "2026-10-16T01:20:00Z", "created_at": "2026-10-16T01:10:00Z"],
                      "last_attempt": ["id": 301, "status": "awaiting_code", "error_message": NSNull()]],
        ]],
        "pool": ["total": 3, "active": 2, "quota_exceeded": 1, "needs_reauth": 0, "five_hour_utilization": 0.4, "weekly_utilization": 0.8,
                 "worst_five_hour_utilization": 0.9, "worst_weekly_utilization": 1.0, "read_count": 3, "servable_count": 2, "weekly_spent_count": 1,
                 "capacity_now": true, "next_capacity_at": NSNull(), "next_weekly_reset": "2026-10-18T00:00:00Z", "windows": ["five_hour": ["capacity_usd": 12.5]],
                 "dry": ["reasons": ["quota_exceeded": 3], "breakdown": "3 out of quota", "recovery": "Sessions will park and resume on their own when a window resets."]],
        "rotation_log": [["id": 61, "at": "2026-10-16T00:30:00Z", "from": ["email": "spot@tadasant.com", "deleted": false], "to": ["email": "ops@tadasant.com", "deleted": false],
                          "reason": "quota_exceeded", "source": "automatic", "triggered_by": "session:1042", "session_id": 1042]],
        "openrouter_key": NSNull(),
        "spot_policy": ["gating_enabled": true, "five_hour_reserve_pct": 15, "weekly_reserve_pct": 20, "max_concurrent_sessions": 4, "preemption_enabled": true,
                        "starvation_age_ceiling_hours": 2, "worker_slots": 4, "ceiling_out_of_reach": false, "effective_ceiling": 4,
                        "decision": ["allowed": false, "reason": "five_hour_pace", "ceiling": "five_hour", "detail": "ahead of the curve", "active_sessions": 3,
                                     "awaiting_sessions": 1, "fleet_cap": 4, "accounts_read": 3, "pool_size": 3, "five_hour": ["label": "5-hour"], "pool_capacity": NSNull()],
                        "hold": [["label": "Why it's held", "sentence": "The 5-hour window is ahead of its curve."]],
                        "paused_count": 1, "preempted_count": 0, "held_count": 1, "overdue_hold_count": 0,
                        "sessions_asleep": "1 asleep.", "sessions_preempted": "None.", "sessions_held": "1 held.", "sessions_starved": "None.",
                        "starvation": ["ceiling_hours": 2, "starved_count": 0, "oldest_hold_age_seconds": 1200, "occupants": []]],
        "fleet_top_up": ["max_running_sessions": 12, "idle_minutes": 5, "min_fire_interval_minutes": 30, "quiet_backlog_interval_minutes": 240,
                         "state": "inside_threshold", "running_sessions": 3, "awaiting_sessions": 1, "asleep_sessions": 2, "headroom": 9, "worker_slots": 4,
                         "ceiling_out_of_reach": true, "effective_ceiling": 4, "under_ceiling_since": "2026-10-16T00:57:00Z", "last_fired_at": NSNull(),
                         "next_fire_at": "2026-10-16T01:02:00Z", "cadence": "at most 48 times a day", "quiet_cadence": "at most 6 times a day", "sentence": "Under its ceiling."],
        "genesis_classes": ["overrides": ["api": "priority"],
                            "kinds": [["key": "api", "label": "API / agent spawn", "description": "Created over the REST API.", "default_class": "spot", "class": "priority",
                                       "overridden": true, "settable": true, "live_sessions": 4],
                                      ["key": "slack", "label": "Slack trigger", "description": "A Slack trigger fired.", "default_class": "priority", "class": "priority",
                                       "overridden": false, "settable": false, "live_sessions": 2]]],
        ]
    }

    func testTheReportDecodesAsThePageRendersIt() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, Self.report()) }])
        let report = try await api.inference(runtime: "claude_code")

        XCTAssertEqual(transport.sent.first?.url.query, "runtime=claude_code")
        let account = try XCTUnwrap(report.accounts?.first)
        XCTAssertTrue(account.isCurrent)
        XCTAssertEqual(account.statusLabel, "Quota Exceeded", "the badge is the effective status, which the reading outranks")
        XCTAssertEqual(account.quota?.fiveHour.percentText, "42.0%")
        XCTAssertEqual(account.quota?.fiveHour.badge, "Allowed")
        XCTAssertNil(account.quota?.sevenDay.badge, "a status recorded for a window that has rolled over is dropped")
        XCTAssertEqual(account.quota?.sevenDay.resetLine(now: Date()), "Window reset")
        XCTAssertEqual(account.credentialLine(now: ZimmerJSON.parseDate("2026-10-16T01:00:00Z")!).text, "Credentials verified against Anthropic 3 days ago.")
        XCTAssertNil(account.credentialTag)
        XCTAssertEqual(account.login.activeAttempt?.status, "awaiting_code")
        XCTAssertNil(account.login.activeAttempt?.verificationURL, "the link is withheld from a key that is not a person")
        XCTAssertEqual(report.pool?.dry?.reasons, ["quota_exceeded": 3])
        XCTAssertEqual(report.rotationLog?.first?.sessionID, 1042)
        XCTAssertNil(report.openrouterKey)
        XCTAssertFalse(report.spotPolicy.decision.allowed)
        XCTAssertEqual(report.spotPolicy.hold.first?.label, "Why it's held")
        XCTAssertTrue(report.fleetTopUp.underCeiling)
        XCTAssertNotNil(report.fleetTopUp.ceilingNote)
        XCTAssertEqual(report.genesisClasses.settable.map(\.key), ["api"])
        XCTAssertEqual(report.genesisClasses.kinds.first?.priorityClass, "priority")
        XCTAssertEqual(report.genesisClasses.kinds.first?.target, "spot")
    }

    func testThePiTabCarriesTheKeyStateAndNoRoster() async throws {
        var pi = Self.report()
        pi["runtime"] = "pi"
        pi["accounts"] = NSNull()
        pi["pool"] = NSNull()
        pi["rotation_log"] = NSNull()
        pi["openrouter_key"] = ["variable": "OPENROUTER_API_KEY", "present": true, "provider_label": "Google Cloud Parameter Manager", "provider_badge": "Parameter Store",
                                "fingerprint": "sha256:3f9a", "path": "projects/p/parameters/k", "project_id": "p", "location": "global",
                                "last_write": ["at": "2026-10-01T00:00:00Z", "action": "set"], "writable": true, "deletable": false, "write_reason": NSNull(),
                                "missing_permissions": []]
        let piResponse = Fixtures.json(200, pi)
        let (api, _) = client([{ _ in piResponse }])
        let report = try await api.inference(runtime: "pi")

        XCTAssertTrue(report.isPi)
        XCTAssertNil(report.accounts)
        XCTAssertEqual(report.openrouterKey?.fingerprint, "sha256:3f9a")
        XCTAssertEqual(report.openrouterKey?.lastWrite?.action, "set")
        XCTAssertFalse(report.showsPolicy)
    }

    func testEachAccountVerbHitsItsRouteWithTheServersParameterNames() async throws {
        let account: [String: Any] = ["id": 20, "email": "new@tadasant.com", "runtime": "codex", "priority": 3, "is_current": false, "status": "active",
                                      "effective_status": "active", "quota_hit_count": 0, "api_key_account": true,
                                      "credentials": ["state": "unverified", "stored": true, "refused": false], "quota": NSNull(),
                                      "login": ["available": false, "active_attempt": NSNull(), "last_attempt": NSNull()]]
        let responses = [
            Fixtures.json(201, ["account": account, "message": "Added new@tadasant.com."]),
            Fixtures.json(200, ["account": account, "pool": ["total": 1, "active": 1, "quota_exceeded": 0, "needs_reauth": 0, "read_count": 0, "servable_count": 1, "weekly_spent_count": 0, "capacity_now": true]]),
            Fixtures.json(200, ["account": account, "message": "Switched to new@tadasant.com"]),
            Fixtures.json(200, ["message": "Deleted new@tadasant.com.", "current_account": NSNull()]),
        ]
        let (api, transport) = client(responses.map { response in { _ in response } })

        let added = try await api.addInferenceAccount(runtime: "codex", email: "new@tadasant.com", priority: 3, apiKey: "sk-test")
        let refreshed = try await api.refreshInferenceAccount(20)
        let activated = try await api.activateInferenceAccount(20)
        let removed = try await api.deleteInferenceAccount(20)

        XCTAssertEqual(added.message, "Added new@tadasant.com.")
        XCTAssertEqual(added.account.credentialTag, "API key")
        XCTAssertEqual(refreshed.pool?.total, 1)
        XCTAssertEqual(activated.message, "Switched to new@tadasant.com")
        XCTAssertNil(removed.currentAccount)
        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "POST /api/v1/inference/accounts", "POST /api/v1/inference/accounts/20/refresh",
            "POST /api/v1/inference/accounts/20/activate", "DELETE /api/v1/inference/accounts/20",
        ])
        let form = body(transport.sent[0])
        XCTAssertEqual(form["runtime"] as? String, "codex")
        XCTAssertEqual(form["email"] as? String, "new@tadasant.com")
        XCTAssertEqual(form["priority"] as? Int, 3)
        XCTAssertEqual(form["api_key"] as? String, "sk-test")
    }

    func testABlankApiKeyIsNotSent() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(422, ["error": "Refused", "message": "Email is required to add an account."]) }])
        await XCTAssertThrowsAsync(try await api.addInferenceAccount(runtime: "claude_code", email: "", priority: 0, apiKey: ""), "a blank email is refused")
        XCTAssertNil(body(transport.sent[0])["api_key"])
    }

    func testTheLoginFlowHitsItsRoutes() async throws {
        let attempt: [String: Any] = ["id": 301, "account_id": 11, "runtime": "codex", "status": "awaiting_user", "terminal": false,
                                      "verification_url": "https://auth.openai.com/codex/device", "verification_code": "WXYZ-7K2Q", "awaiting_code": false,
                                      "code_received": false, "error_message": NSNull(), "expires_at": "2026-10-16T01:20:00Z", "created_at": "2026-10-16T01:10:00Z"]
        let responses = [
            Fixtures.json(201, ["login": attempt]),
            Fixtures.json(200, ["login": attempt, "account": NSNull()]),
            Fixtures.json(200, ["login": attempt]),
            Fixtures.json(200, ["login": attempt]),
        ]
        let (api, transport) = client(responses.map { response in { _ in response } })

        let started = try await api.startInferenceLogin(accountID: 11)
        let polled = try await api.inferenceLogin(301)
        _ = try await api.submitInferenceLoginCode(301, code: "abc-123")
        _ = try await api.cancelInferenceLogin(301)

        XCTAssertEqual(started.verificationCode, "WXYZ-7K2Q")
        XCTAssertTrue(polled.login.showsLink)
        XCTAssertEqual(polled.login.headline, "Open the link and enter the one-time code")
        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "POST /api/v1/inference/logins", "GET /api/v1/inference/logins/301",
            "POST /api/v1/inference/logins/301/code", "POST /api/v1/inference/logins/301/cancel",
        ])
        XCTAssertEqual(body(transport.sent[0])["account_id"] as? Int, 11)
        XCTAssertEqual(body(transport.sent[2])["code"] as? String, "abc-123")
    }

    func testThePolicyWritesSendTheToolsParameterNames() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["changed": ["enabled", "max_concurrent_sessions"], "spot_policy": Self.report()["spot_policy"]!]) },
            { _ in Fixtures.json(200, ["changed": ["idle_minutes"], "fleet_top_up": Self.report()["fleet_top_up"]!]) },
            { _ in Fixtures.json(200, ["message": "API / agent spawn is now priority. 4 live sessions reclassified.", "genesis_classes": Self.report()["genesis_classes"]!]) },
            { _ in Fixtures.json(200, ["message": "Genesis classes reset to defaults.", "genesis_classes": Self.report()["genesis_classes"]!]) },
        ])

        let spot = try await api.updateSpotPolicy(SpotPolicyChange(enabled: false, maxConcurrentSessions: 6))
        let topUp = try await api.updateFleetTopUp(FleetTopUpChange(idleMinutes: 10))
        let moved = try await api.setGenesisClass("api", to: "priority")
        let reset = try await api.resetGenesisClasses()

        XCTAssertEqual(spot.maxConcurrentSessions, 4, "the server's policy is what comes back")
        XCTAssertEqual(topUp.idleMinutes, 5)
        XCTAssertEqual(moved.message, "API / agent spawn is now priority. 4 live sessions reclassified.")
        XCTAssertEqual(reset.genesisClasses.kinds.count, 2)
        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "PATCH /api/v1/inference/spot_policy", "PATCH /api/v1/inference/fleet_top_up",
            "PATCH /api/v1/inference/genesis/api", "DELETE /api/v1/inference/genesis",
        ])
        let spotBody = body(transport.sent[0])
        XCTAssertEqual(spotBody["enabled"] as? Bool, false)
        XCTAssertEqual(spotBody["max_concurrent_sessions"] as? Int, 6)
        XCTAssertEqual(spotBody.count, 2, "only the knobs changed are sent")
        XCTAssertEqual(body(transport.sent[1]) as? [String: Int], ["idle_minutes": 10])
        XCTAssertEqual(body(transport.sent[2])["priority_class"] as? String, "priority")
    }

    func testTheWholeFormIsSentUnderEveryKnobsName() {
        let policy = SpotPolicy(gatingEnabled: true, fiveHourReservePct: 15, weeklyReservePct: 20, maxConcurrentSessions: 4, preemptionEnabled: false,
                                starvationAgeCeilingHours: 0, decision: .init(allowed: true), starvation: .init(ceilingHours: nil, starvedCount: 0))
        XCTAssertEqual(Set(SpotPolicyChange(policy).json.keys),
                       ["enabled", "five_hour_reserve_pct", "weekly_reserve_pct", "max_concurrent_sessions", "preemption_enabled", "starvation_age_ceiling_hours"])
    }

    func testAForbiddenWriteCarriesTheServersSentence() async throws {
        let (api, _) = client([{ _ in Fixtures.json(403, ["error": "Forbidden", "message": "Only a person can do this: it takes the iOS app's sign-in, acting as you, or the web UI"]) }])
        do {
            _ = try await api.activateInferenceAccount(11)
            XCTFail("a 403 is an error")
        } catch let ZimmerError.http(status, message) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(message, "Only a person can do this: it takes the iOS app's sign-in, acting as you, or the web UI")
        }
    }

    func testTheDurationsReadAsThePageWordsThem() {
        XCTAssertEqual(InferenceFormat.duration(30), "< 1m")
        XCTAssertEqual(InferenceFormat.duration(2 * 3600 + 10 * 60), "2h 10m")
        XCTAssertEqual(InferenceFormat.duration(4 * 86_400 + 3 * 3600), "4d 3h")
        XCTAssertEqual(InferenceFormat.ago(Date().addingTimeInterval(-3 * 86_400)), "3 days ago")
        XCTAssertEqual(InferenceFormat.ago(Date().addingTimeInterval(-60)), "1 minute ago")
    }

    // MARK: - The fake

    func testTheFakesRosterHasACurrentAQuotaExceededAndAFailingProbe() async throws {
        let fake = FakeZimmerAPI()
        let report = try await fake.inference(runtime: "claude_code")
        let accounts = try XCTUnwrap(report.accounts)
        XCTAssertEqual(accounts.map(\.email), ["ops@tadasant.com", "spot@tadasant.com", "backup@tadasant.com"])
        XCTAssertEqual(accounts.filter(\.isCurrent).map(\.id), [11])
        XCTAssertEqual(accounts[1].statusLabel, "Quota Exceeded")
        XCTAssertNotNil(accounts[2].probeError)
        XCTAssertEqual(accounts[2].credentialTag, "Token refused")
        XCTAssertEqual(report.pool?.quotaExceeded, 1)
        XCTAssertNil(report.pool?.dry)
        XCTAssertEqual(report.rotationLog?.count, 3)
        let again = try await fake.inference(runtime: "claude_code")
        XCTAssertEqual(report, again, "a second read is the same page")
    }

    func testTheFakeMovesTheCurrentMarkerAndLogsTheRotation() async throws {
        let fake = FakeZimmerAPI()
        let switched = try await fake.activateInferenceAccount(12)
        XCTAssertEqual(switched.message, "Switched to spot@tadasant.com")
        let report = try await fake.inference(runtime: "claude_code")
        XCTAssertEqual(report.accounts?.filter(\.isCurrent).map(\.id), [12])
        XCTAssertEqual(report.rotationLog?.first?.to.email, "spot@tadasant.com")
        XCTAssertEqual(report.rotationLog?.first?.triggeredBy, FakeInference.actor)
        await XCTAssertThrowsAsync(try await fake.activateInferenceAccount(13), "a refused token cannot be switched to")
        await XCTAssertThrowsAsync(try await fake.activateInferenceAccount(15), "an account with no credentials cannot be switched to")
    }

    func testTheFakesRefreshMovesTheReadingOrFails() async throws {
        let fake = FakeZimmerAPI()
        let refreshed = try await fake.refreshInferenceAccount(11)
        XCTAssertEqual(refreshed.account.quota?.fiveHour.percentText, "45.0%")
        XCTAssertNil(refreshed.account.probeError)
        let failed = try await fake.refreshInferenceAccount(13)
        XCTAssertNotNil(failed.account.probeError)
    }

    func testDeletingTheCurrentAccountHandsOver() async throws {
        let fake = FakeZimmerAPI()
        let removed = try await fake.deleteInferenceAccount(11)
        XCTAssertEqual(removed.message, "Deleted ops@tadasant.com. Activated spot@tadasant.com as the current account.")
        XCTAssertEqual(removed.currentAccount?.id, 12)
        let report = try await fake.inference(runtime: "claude_code")
        XCTAssertEqual(report.accounts?.count, 2)
    }

    func testTheFakesCodexLoginWalksToSucceededOnSuccessivePolls() async throws {
        let fake = FakeZimmerAPI()
        let added = try await fake.addInferenceAccount(runtime: "codex", email: "new@tadasant.com", priority: 2, apiKey: nil)
        XCTAssertEqual(added.message, "Added new@tadasant.com. Authenticate it to capture credentials.")
        XCTAssertFalse(added.account.credentials.stored)
        let attempt = try await fake.startInferenceLogin(accountID: added.account.id)
        XCTAssertEqual(attempt.status, "starting")
        let first = try await fake.inferenceLogin(attempt.id)
        XCTAssertEqual(first.login.status, "awaiting_user")
        XCTAssertEqual(first.login.verificationCode, "WXYZ-7K2Q")
        XCTAssertNotNil(first.login.verificationURL)
        // The code stays up for five polls — ten seconds at the sheet's cadence.
        for _ in 2...5 {
            let polled = try await fake.inferenceLogin(attempt.id)
            XCTAssertEqual(polled.login.status, "awaiting_user")
        }
        let sixth = try await fake.inferenceLogin(attempt.id)
        XCTAssertEqual(sixth.login.status, "completing")
        let seventh = try await fake.inferenceLogin(attempt.id)
        XCTAssertTrue(seventh.login.succeeded)
        XCTAssertTrue(seventh.account?.credentials.stored ?? false, "the login captured credentials")
        XCTAssertEqual(seventh.account?.status, "active")
        await XCTAssertThrowsAsync(try await fake.startInferenceLogin(accountID: 14), "an API-key account has no login flow")
    }

    func testTheFakesClaudeLoginWaitsForThePastedCode() async throws {
        let fake = FakeZimmerAPI()
        let attempt = try await fake.startInferenceLogin(accountID: 13)
        let first = try await fake.inferenceLogin(attempt.id)
        XCTAssertEqual(first.login.status, "awaiting_user")
        let awaiting = try await fake.inferenceLogin(attempt.id).login
        XCTAssertEqual(awaiting.status, "awaiting_code")
        XCTAssertTrue(awaiting.showsLink, "the link stays while the code is wanted")
        let still = try await fake.inferenceLogin(attempt.id)
        XCTAssertEqual(still.login.status, "awaiting_code")
        await XCTAssertThrowsAsync(try await fake.submitInferenceLoginCode(attempt.id, code: " "), "a blank code is refused")
        _ = try await fake.submitInferenceLoginCode(attempt.id, code: "code-1")
        let completing = try await fake.inferenceLogin(attempt.id)
        XCTAssertEqual(completing.login.status, "completing")
        let done = try await fake.inferenceLogin(attempt.id)
        XCTAssertTrue(done.login.succeeded)
        XCTAssertEqual(done.account?.credentials.state, "verified")
        XCTAssertNil(done.account?.probeError)
        let canceled = try await fake.cancelInferenceLogin(attempt.id)
        XCTAssertEqual(canceled.status, "succeeded", "a finished attempt is left as it finished")
    }

    func testTheFakeRefusesAPolicyOutOfRangeAndKeepsTheStoredValue() async throws {
        let fake = FakeZimmerAPI()
        do {
            _ = try await fake.updateSpotPolicy(SpotPolicyChange(maxConcurrentSessions: 250))
            XCTFail("250 is out of range")
        } catch let ZimmerError.http(status, message) {
            XCTAssertEqual(status, 422)
            XCTAssertEqual(message, "Spot max concurrent sessions must be less than or equal to 100")
        }
        let unchanged = try await fake.inference(runtime: "claude_code")
        XCTAssertEqual(unchanged.spotPolicy.maxConcurrentSessions, 4)
        let saved = try await fake.updateSpotPolicy(SpotPolicyChange(maxConcurrentSessions: 8))
        XCTAssertEqual(saved.maxConcurrentSessions, 8)
        XCTAssertTrue(saved.ceilingOutOfReach)
        await XCTAssertThrowsAsync(try await fake.updateFleetTopUp(FleetTopUpChange(idleMinutes: 0)), "a minute is the floor")
        await XCTAssertThrowsAsync(try await fake.updateSpotPolicy(SpotPolicyChange()), "nothing to change")
    }

    func testTheFakeReclassifiesAndResetsGenesisKinds() async throws {
        let fake = FakeZimmerAPI()
        let moved = try await fake.setGenesisClass("api", to: "priority")
        XCTAssertEqual(moved.message, "API / agent spawn is now priority. 4 live sessions reclassified.")
        XCTAssertEqual(moved.genesisClasses.kinds.first(where: { $0.key == "api" })?.overridden, true)
        await XCTAssertThrowsAsync(try await fake.setGenesisClass("slack", to: "spot"), "a trigger-backed kind is refused")
        let reset = try await fake.resetGenesisClasses()
        XCTAssertTrue(reset.genesisClasses.overrides.isEmpty)
    }

    func testARelayOnlyGrantIsRefusedEveryWriteAndSeesNoLoginSecrets() async throws {
        let person = try await FakeZimmerAPI().inference(runtime: "codex")
        XCTAssertNotNil(person.accounts?[1].login.activeAttempt?.verificationURL, "a person sees the in-flight login's link")

        let relay = FakeZimmerAPI(relayOnly: true)
        let relayed = try await relay.inference(runtime: "codex")
        XCTAssertEqual(relayed.accounts?[1].login.activeAttempt?.status, "awaiting_user", "the relay grant still knows a login is in progress")
        XCTAssertNil(relayed.accounts?[1].login.activeAttempt?.verificationURL, "without the link or the code")
        XCTAssertNil(relayed.accounts?[1].login.activeAttempt?.verificationCode)
        for write: () async throws -> Void in [
            { _ = try await relay.activateInferenceAccount(12) },
            { _ = try await relay.deleteInferenceAccount(12) },
            { _ = try await relay.refreshInferenceAccount(11) },
            { _ = try await relay.addInferenceAccount(runtime: "codex", email: "x@y.z", priority: 0, apiKey: nil) },
            { _ = try await relay.startInferenceLogin(accountID: 13) },
            { _ = try await relay.inferenceLogin(300) },
            { _ = try await relay.updateSpotPolicy(SpotPolicyChange(enabled: false)) },
            { _ = try await relay.updateFleetTopUp(FleetTopUpChange(idleMinutes: 2)) },
            { _ = try await relay.setGenesisClass("api", to: "priority") },
            { _ = try await relay.resetGenesisClasses() },
        ] {
            do {
                try await write()
                XCTFail("a relay grant may not write")
            } catch let ZimmerError.http(status, message) {
                XCTAssertEqual(status, 403)
                XCTAssertEqual(message, FakeInference.relayRefusal)
            }
        }
        let after = try await relay.inference(runtime: "claude_code")
        XCTAssertEqual(after.accounts?.filter(\.isCurrent).map(\.id), [11], "nothing changed")
    }
}
