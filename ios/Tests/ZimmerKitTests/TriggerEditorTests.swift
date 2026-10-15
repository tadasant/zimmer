import XCTest
@testable import ZimmerKit

/// Creating, editing and deleting a trigger, and the two pickers the form fetches.
final class TriggerEditorTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func json(_ request: HTTPRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
    }

    private func schedule(interval: String = "1", unit: String = "days", time: String = "02:00", serverID: Int? = nil) -> ConditionDraft {
        var configuration = ConditionConfiguration()
        configuration.interval = interval
        configuration.unit = unit
        configuration.time = time
        return ConditionDraft(serverID: serverID, type: "schedule", configuration: configuration)
    }

    func testCreateSendsEveryParameterUnderTheAPIsNames() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(201, [
            "trigger": ["id": 9, "name": "Nightly", "status": "enabled", "conditions": [["id": 90, "condition_type": "schedule", "configuration": ["unit": "days"]]]],
            "warnings": ["Agent root 'ghost' is not in this deployment's catalog."],
        ]) }])
        var slack = ConditionDraft(type: "slack")
        slack.configuration.channelID = "C0A6BF8T45R"
        slack.configuration.channelName = "zimmer"
        slack.configuration.eventType = "bot_mention"
        slack.configuration.threadTS = "1767504875.131659"
        let draft = TriggerDraft(
            name: "Nightly", agentRootName: "ghost", promptTemplate: "Sweep {{date}}", goal: "Green PRs", reuseSession: true,
            maxSessionsPerMinute: 3, skipIfPendingSession: true, coalesceWindowSeconds: 0, schedulingClass: "spot", precedence: 40,
            mcpServers: ["github"], catalogSkills: ["open-pr"], catalogHooks: [], catalogPlugins: ["zimmer-ops"],
            conditions: [schedule(), slack], removedConditionIDs: [7]
        )

        let written = try await api.createTrigger(draft)

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, ["POST /api/v1/triggers"])
        let body = json(transport.sent[0])
        XCTAssertEqual(body["name"] as? String, "Nightly")
        XCTAssertEqual(body["agent_root_name"] as? String, "ghost")
        XCTAssertEqual(body["prompt_template"] as? String, "Sweep {{date}}")
        XCTAssertEqual(body["goal"] as? String, "Green PRs")
        XCTAssertEqual(body["reuse_session"] as? Bool, true)
        XCTAssertEqual(body["skip_if_pending_session"] as? Bool, true)
        XCTAssertEqual(body["max_sessions_per_minute"] as? Int, 3)
        XCTAssertEqual(body["coalesce_window_seconds"] as? Int, 0, "0 is off, not blank")
        XCTAssertEqual(body["scheduling_class"] as? String, "spot")
        XCTAssertEqual(body["precedence"] as? Int, 40)
        XCTAssertEqual(body["mcp_servers"] as? [String], ["github"])
        XCTAssertEqual(body["catalog_skills"] as? [String], ["open-pr"])
        XCTAssertEqual(body["catalog_hooks"] as? [String], [], "an empty list is sent: it means the trigger says nothing")
        XCTAssertEqual(body["catalog_plugins"] as? [String], ["zimmer-ops"])
        XCTAssertNil(body["enqueue_messages"], "the re-use switches are left alone unless set")
        XCTAssertNil(body["resuscitate_archived"])
        XCTAssertNil(body["status"])
        XCTAssertNil(body["last_session_id"])
        let conditions = body["trigger_conditions_attributes"] as? [[String: Any]] ?? []
        XCTAssertEqual(conditions.count, 3)
        XCTAssertEqual(conditions[0]["condition_type"] as? String, "schedule")
        XCTAssertNil(conditions[0]["id"], "a condition drafted in the form has no id yet")
        let scheduleConfig = conditions[0]["configuration"] as? [String: Any] ?? [:]
        XCTAssertEqual(scheduleConfig["interval"] as? Int, 1)
        XCTAssertEqual(scheduleConfig["unit"] as? String, "days")
        XCTAssertEqual(scheduleConfig["time"] as? String, "02:00")
        XCTAssertEqual(scheduleConfig["timezone"] as? String, "UTC")
        XCTAssertNil(scheduleConfig["day_of_week"], "a daily schedule names no weekday")
        XCTAssertNil(scheduleConfig["scheduled_at"])
        let slackConfig = conditions[1]["configuration"] as? [String: Any] ?? [:]
        XCTAssertEqual(slackConfig["channel_id"] as? String, "C0A6BF8T45R")
        XCTAssertEqual(slackConfig["channel_name"] as? String, "zimmer")
        XCTAssertEqual(slackConfig["event_type"] as? String, "bot_mention")
        XCTAssertEqual(slackConfig["thread_ts"] as? String, "1767504875.131659")
        XCTAssertNil(slackConfig["allowed_user_ids"], "sent only when there are any")
        XCTAssertEqual(conditions[2]["id"] as? Int, 7)
        XCTAssertEqual(conditions[2]["_destroy"] as? String, "1")
        XCTAssertEqual(written.trigger.id, 9)
        XCTAssertEqual(written.trigger.conditions.first?.id, 90)
        XCTAssertEqual(written.warnings.count, 1)
        XCTAssertNotNil(written.notice)
    }

    func testBlankNumbersAreNullAndTheSwitchesGoWhenSet() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, ["trigger": ["id": 5, "name": "N", "status": "enabled", "conditions": []], "reclassified_waiting_sessions": 2]) }])
        var draft = TriggerDraft(name: "N", agentRootName: "zimmer", promptTemplate: "p", conditions: [schedule(serverID: 51)])
        draft.enqueueMessages = true
        draft.resuscitateArchived = false
        draft.lastSessionID = 1031
        draft.status = "disabled"

        let written = try await api.updateTrigger(5, draft)

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, ["PATCH /api/v1/triggers/5"])
        let body = json(transport.sent[0])
        XCTAssertTrue(body["max_sessions_per_minute"] is NSNull, "blank is null: no limit")
        XCTAssertTrue(body["coalesce_window_seconds"] is NSNull, "blank is null: the default")
        XCTAssertTrue(body["precedence"] is NSNull)
        XCTAssertTrue(body["scheduling_class"] is NSNull)
        XCTAssertEqual(body["goal"] as? String, "")
        XCTAssertEqual(body["enqueue_messages"] as? Bool, true)
        XCTAssertEqual(body["resuscitate_archived"] as? Bool, false)
        XCTAssertEqual(body["last_session_id"] as? Int, 1031)
        XCTAssertEqual(body["status"] as? String, "disabled")
        let conditions = body["trigger_conditions_attributes"] as? [[String: Any]] ?? []
        XCTAssertEqual(conditions.first?["id"] as? Int, 51, "a kept condition is changed in place")
        XCTAssertEqual(written.reclassifiedWaitingSessions, 2)
        XCTAssertEqual(written.notice, "2 waiting sessions moved to the new scheduling class.")
    }

    func testEachConditionTypeSendsOnlyItsOwnKeys() {
        var minutes = schedule(interval: "15", unit: "minutes", time: "09:00")
        minutes.configuration.dayOfWeek = "monday"
        let minutesConfig = minutes.body["configuration"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(minutesConfig.keys), ["interval", "unit"], "a schedule in minutes shows no time, weekday or zone, so sends none")

        var weekly = schedule(unit: "weeks", time: "09:00")
        weekly.configuration.dayOfWeek = "monday"
        weekly.configuration.timezone = "Eastern Time (US & Canada)"
        let weeklyConfig = weekly.body["configuration"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(weeklyConfig.keys), ["interval", "unit", "time", "day_of_week", "timezone"])

        var once = ConditionDraft(type: "schedule", scheduleMode: .oneTime)
        once.configuration.scheduledAt = "2026-04-15T14:30"
        once.configuration.unit = "days"
        let onceConfig = once.body["configuration"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(onceConfig.keys), ["scheduled_at", "timezone"], "one-time sends no recurring fields")
        XCTAssertEqual(onceConfig["scheduled_at"] as? String, "2026-04-15T14:30")

        var dm = ConditionDraft(type: "slack")
        dm.configuration.channelID = "C1"
        dm.configuration.channelName = "left-over"
        dm.configuration.eventType = "dm_message"
        let dmConfig = dm.body["configuration"] as? [String: Any] ?? [:]
        XCTAssertEqual(dmConfig["channel_id"] as? String, "", "a DM condition's channel is blanked, as the web form blanks it")
        XCTAssertEqual(dmConfig["channel_name"] as? String, "")

        var whatsapp = ConditionDraft(type: "whatsapp")
        whatsapp.configuration.chatID = "120363012345678901@g.us"
        whatsapp.configuration.mode = "addressed"
        whatsapp.configuration.keywords = ["zimmer", "bot"]
        whatsapp.configuration.includeFromMe = true
        let whatsappConfig = whatsapp.body["configuration"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(whatsappConfig.keys), ["chat_id", "chat_name", "mode", "keywords", "include_from_me"])
        XCTAssertEqual(whatsappConfig["keywords"] as? [String], ["zimmer", "bot"])
        XCTAssertEqual(whatsappConfig["include_from_me"] as? Bool, true)

        var email = ConditionDraft(type: "email")
        email.configuration.query = "to:zimmer+bugs@example.com"
        XCTAssertEqual(Set((email.body["configuration"] as? [String: Any] ?? [:]).keys), ["query", "include_automated"])

        var event = ConditionDraft(type: "ao_event")
        event.configuration.eventName = "session_failed"
        XCTAssertEqual(Set((event.body["configuration"] as? [String: Any] ?? [:]).keys), ["event_name"])
        event.configuration.watchedSessionID = "1042"
        XCTAssertEqual((event.body["configuration"] as? [String: Any])?["watched_session_id"] as? String, "1042")

        var system = ConditionDraft(type: "system_event")
        system.configuration.eventName = "quota_available"
        XCTAssertEqual((system.body["configuration"] as? [String: Any])?["event_name"] as? String, "quota_available")

        var label = ConditionDraft(type: "github_label")
        label.configuration.repos = ["tadasant/zimmer"]
        label.configuration.labels = ["ready to merge"]
        label.configuration.excludeLabels = ["hold"]
        let labelConfig = label.body["configuration"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(labelConfig.keys), ["repos", "target", "labels"], "a label condition carries no exclusions")
        XCTAssertEqual(labelConfig["target"] as? String, "pull_request")

        var issue = ConditionDraft(type: "github_issue")
        issue.configuration.repos = ["tadasant/zimmer"]
        issue.configuration.excludeLabels = ["hold"]
        XCTAssertEqual(Set((issue.body["configuration"] as? [String: Any] ?? [:]).keys), ["repos", "exclude_labels"])
    }

    func testARefusalCarriesEachReasonAndSavesNothing() async throws {
        let (api, _) = client([
            { _ in Fixtures.json(422, ["error": "Validation failed", "message": "Name can't be blank, Trigger conditions configuration unit must be one of: minutes, hours, days, weeks",
                                       "messages": ["Name can't be blank", "Trigger conditions configuration unit must be one of: minutes, hours, days, weeks"]]) },
            { _ in Fixtures.json(422, ["error": "Validation failed", "message": "Prompt template can't be blank"]) },
        ])
        let draft = TriggerDraft(name: "", agentRootName: "zimmer", promptTemplate: "p", conditions: [schedule()])

        do {
            _ = try await api.createTrigger(draft)
            XCTFail("a 422 is a refusal")
        } catch let refusal as TriggerValidationError {
            XCTAssertEqual(refusal.messages.count, 2, "read reason by reason, not split on the commas a reason contains")
            XCTAssertEqual(refusal.messages.first, "Name can't be blank")
            XCTAssertEqual(refusal.headline, "2 errors prohibited this trigger from being saved:")
        }
        do {
            _ = try await api.updateTrigger(5, draft)
            XCTFail("a 422 is a refusal")
        } catch let refusal as TriggerValidationError {
            XCTAssertEqual(refusal.messages, ["Prompt template can't be blank"], "an envelope without the list still has its sentence")
            XCTAssertEqual(refusal.headline, "1 error prohibited this trigger from being saved:")
        }
    }

    func testDeleteAndThePickersHitTheirRoutes() async throws {
        let (api, transport) = client([
            { _ in HTTPResponse(statusCode: 204, headers: [:], body: Data()) },
            { _ in Fixtures.json(200, ["channels": [
                ["id": "C1", "name": "zimmer", "is_private": false, "num_members": 12],
                ["id": "C2", "name": "ops", "is_private": true, "num_members": NSNull()],
            ]]) },
            { _ in Fixtures.json(200, ["chats": [
                ["id": "120363012345678901@g.us", "name": "Ops on call", "is_group": true, "last_message_at": "2026-10-11T01:00:00Z", "participant_count": 5],
                ["id": "15551234567@s.whatsapp.net", "name": "15551234567@s.whatsapp.net", "is_group": false, "last_message_at": NSNull(), "participant_count": NSNull()],
            ]]) },
            { _ in Fixtures.json(503, ["error": "Slack is not configured", "message": "Slack is not configured"]) },
        ])

        try await api.deleteTrigger(6)
        let channels = try await api.triggerChannels()
        let chats = try await api.whatsappChats()

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "DELETE /api/v1/triggers/6", "GET /api/v1/triggers/channels", "GET /api/v1/triggers/whatsapp_chats",
        ])
        XCTAssertEqual(channels.map(\.label), ["#zimmer", "🔒 ops"])
        XCTAssertEqual(channels[0].memberCount, 12)
        XCTAssertNil(channels[1].memberCount)
        XCTAssertEqual(chats.map(\.label), ["Ops on call (group)", "15551234567@s.whatsapp.net"])
        XCTAssertNotNil(chats[0].lastMessageAt)
        XCTAssertEqual(chats[0].participantCount, 5)
        do {
            _ = try await api.triggerChannels()
            XCTFail("a 503 is an error")
        } catch let error as ZimmerError {
            XCTAssertEqual(error, .http(status: 503, message: "Slack is not configured"), "the form prints the server's sentence")
        }
    }

    func testAStoredConditionReadsBackIntoTheFormHoweverItWasWritten() throws {
        // What the web form posted: strings for numbers, "1" for a flag, a textarea for a list.
        let web = try JSONDecoder().decode(TriggerSummary.Condition.self, from: Data("""
        {"id": 51, "condition_type": "whatsapp", "description": "WhatsApp: every message in Ops",
         "configuration": {"chat_id": "120363012345678901@g.us", "chat_name": "Ops", "mode": "listen", "keywords": "zimmer\\nbot\\n", "include_from_me": "1", "seen_messages": {"a": 1}}}
        """.utf8))
        XCTAssertEqual(web.id, 51)
        XCTAssertEqual(web.configuration.chatID, "120363012345678901@g.us")
        XCTAssertEqual(web.configuration.keywords, ["zimmer", "bot"])
        XCTAssertTrue(web.configuration.includeFromMe)

        // What an API caller posted: real numbers, booleans and arrays.
        let api = try JSONDecoder().decode(TriggerSummary.Condition.self, from: Data("""
        {"id": 52, "condition_type": "schedule", "configuration": {"interval": 6, "unit": "hours", "last_checked_at": "x"}}
        """.utf8))
        XCTAssertEqual(api.configuration.interval, "6")
        XCTAssertEqual(api.configuration.unit, "hours")
        XCTAssertEqual(api.configuration.timezone, "UTC", "the form's default where nothing is stored")
        let draft = ConditionDraft(condition: api)
        XCTAssertEqual(draft.serverID, 52)
        XCTAssertEqual(draft.scheduleMode, .recurring)
        XCTAssertEqual(draft.description, "Every 6 hours")

        let once = try JSONDecoder().decode(TriggerSummary.Condition.self, from: Data("""
        {"condition_type": "schedule", "configuration": {"scheduled_at": "2026-04-15T14:30:00", "timezone": "Eastern Time (US & Canada)"}}
        """.utf8))
        XCTAssertEqual(ConditionDraft(condition: once).scheduleMode, .oneTime)
        XCTAssertNil(once.id)

        // A trigger read before this change, with no configuration in its conditions, still reads.
        let bare = try JSONDecoder().decode(TriggerSummary.Condition.self, from: Data(#"{"condition_type": "slack"}"#.utf8))
        XCTAssertEqual(bare.configuration, ConditionConfiguration())
    }

    func testTheDraftOpensOnTheTriggersStoredSettings() {
        let trigger = FakeZimmerAPI.sampleTriggers()[0]
        let draft = TriggerDraft(editing: trigger)
        XCTAssertEqual(draft.name, "Nightly dependency sweep")
        XCTAssertEqual(draft.agentRootName, "zimmer")
        XCTAssertTrue(draft.reuseSession)
        XCTAssertNil(draft.enqueueMessages, "the switch is left to the web page")
        XCTAssertEqual(draft.precedence, 40)
        XCTAssertEqual(draft.selections[.skills], ["open-pr", "wait-for-ci"])
        XCTAssertEqual(draft.conditions.count, 1)
        XCTAssertEqual(draft.conditions[0].serverID, 51)
        XCTAssertEqual(draft.conditions[0].configuration.time, "02:00")
        XCTAssertFalse(draft.hasSlackCondition)
        XCTAssertEqual(TriggerDraft.blank().conditions.map(\.type), ["slack"], "the web's new page starts with a Slack condition")
    }

    func testTheTimeZonesAreTheWebsNamesWithUTCFirst() {
        let options = ScheduleTimeZone.options(including: "")
        XCTAssertEqual(options.first?.name, "UTC")
        XCTAssertEqual(options.filter { $0.name == "UTC" }.count, 1)
        XCTAssertTrue(options.contains { $0.name == "Eastern Time (US & Canada)" && $0.identifier == "America/New_York" })
        XCTAssertEqual(options.count, 1 + ScheduleTimeZone.us.count + ScheduleTimeZone.rest.count - 1)
        let january = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 1, day: 15))!
        XCTAssertEqual(ScheduleTimeZone(name: "Eastern Time (US & Canada)", identifier: "America/New_York").label(at: january), "(GMT-05:00) Eastern Time (US & Canada)")
        XCTAssertEqual(ScheduleTimeZone.options(including: "Asia/Kolkata").first?.name, "Asia/Kolkata", "a stored identifier is kept rather than moved")
    }

    func testTheFakeRefusesAsTheServerDoesAndListsWhatItSaved() async throws {
        let api = FakeZimmerAPI()
        let blank = TriggerDraft(name: "  ", agentRootName: "", promptTemplate: "", conditions: [ConditionDraft(type: "slack")])
        do {
            _ = try await api.createTrigger(blank)
            XCTFail("refused")
        } catch let refusal as TriggerValidationError {
            XCTAssertEqual(refusal.messages, [
                "Name can't be blank", "Agent root name can't be blank", "Prompt template can't be blank",
                "Trigger conditions configuration must include channel_id for Slack conditions",
            ])
        }
        let before = try await api.triggers().count

        var draft = TriggerDraft(name: "Hourly inbox sweep", agentRootName: "zimmer", promptTemplate: "Sweep the inbox.", conditions: [schedule(interval: "6", unit: "hours", time: "")])
        let created = try await api.createTrigger(draft)
        XCTAssertEqual(created.trigger.name, "Hourly inbox sweep")
        XCTAssertEqual(created.trigger.conditions.first?.description, "Every 6 hours")
        XCTAssertNotNil(created.trigger.conditions.first?.id)
        XCTAssertEqual(created.trigger.effectiveSchedulingClass, "spot", "a schedule is spot by default")
        XCTAssertTrue(created.trigger.coalesceWindowInert)
        XCTAssertTrue(created.warnings.isEmpty)
        let list = try await api.triggers()
        XCTAssertEqual(list.count, before + 1)
        XCTAssertEqual(list.first?.id, created.trigger.id, "newest first")

        draft.name = "Hourly inbox sweep (quiet)"
        draft.conditions[0].serverID = created.trigger.conditions.first?.id
        draft.schedulingClass = "priority"
        let updated = try await api.updateTrigger(created.trigger.id, draft)
        XCTAssertEqual(updated.trigger.name, "Hourly inbox sweep (quiet)")
        XCTAssertEqual(updated.trigger.conditions.first?.id, created.trigger.conditions.first?.id, "changed in place")
        XCTAssertEqual(updated.reclassifiedWaitingSessions, 0)

        // Turning re-use off under a switch the form does not send is refused, as on the server.
        let nightly = try await api.trigger(5).trigger
        var reuseOff = TriggerDraft(editing: nightly)
        reuseOff.reuseSession = false
        do {
            _ = try await api.updateTrigger(5, reuseOff)
            XCTFail("refused")
        } catch let refusal as TriggerValidationError {
            XCTAssertEqual(refusal.messages, ["Enqueue messages can only be enabled when re-use session is enabled"])
        }

        try await api.deleteTrigger(created.trigger.id)
        let after = try await api.triggers()
        XCTAssertEqual(after.count, before)
        let channels = try await api.triggerChannels()
        let chats = try await api.whatsappChats()
        XCTAssertEqual(channels.map(\.name), ["zimmer", "support", "ops-private", "general"])
        XCTAssertEqual(chats.first?.label, "Ops on call (group)")
        let unknownRoot = TriggerDraft(name: "x", agentRootName: "ghost", promptTemplate: "p", conditions: [schedule()])
        let saved = try await api.createTrigger(unknownRoot)
        XCTAssertTrue(saved.trigger.agentRootMissing)
        XCTAssertEqual(saved.warnings.count, 1, "saved, with the server's warning")
    }
}
