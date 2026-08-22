# frozen_string_literal: true

require "test_helper"

# The web UI's "Pause Until" endpoint. It is the browser-side twin of the
# wake_me_up_later MCP tool, so the cases that matter here are the ones a browser
# can produce and a tool call cannot: a naive local wall-clock time with the
# operator's own timezone, an omitted resume prompt, and a card whose button
# outlived the session state it was rendered for.
class SessionsControllerPauseUntilTest < ActionDispatch::IntegrationTest
  def future_wake_at(offset = 1.hour)
    offset.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S")
  end

  test "sleeps the session and schedules a one-time wake trigger" do
    session = sessions(:needs_input)
    wake_at = future_wake_at

    assert_difference "Trigger.count", 1 do
      post pause_until_session_url(session), params: { wake_at: wake_at, timezone: "UTC" }, as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert_equal "waiting", body["status"]
    assert_equal wake_at, body["wake_at"]
    assert_equal "UTC", body["timezone"]
    assert_not body["pending_sleep"]

    trigger = Trigger.find(body["trigger_id"])
    assert trigger.reuse_session
    assert_equal session.id, trigger.last_session_id
    assert trigger.trigger_conditions.sole.one_time_schedule?
    assert session.reload.waiting?
  end

  test "defaults the resume prompt when none is supplied" do
    post pause_until_session_url(sessions(:needs_input)), params: { wake_at: future_wake_at }, as: :json

    assert_response :success
    assert_equal AutomatedPrompts::PAUSE_UNTIL_WAKE, Trigger.find(JSON.parse(response.body)["trigger_id"]).prompt_template
  end

  test "uses a supplied resume prompt verbatim" do
    post pause_until_session_url(sessions(:needs_input)),
      params: { wake_at: future_wake_at, prompt: "Re-check the deploy" }, as: :json

    assert_equal "Re-check the deploy", Trigger.find(JSON.parse(response.body)["trigger_id"]).prompt_template
  end

  test "interprets the wall-clock time in the browser's timezone, not the server's" do
    wake_at = 1.day.from_now.in_time_zone("America/New_York").strftime("%Y-%m-%dT%H:%M:%S")

    post pause_until_session_url(sessions(:needs_input)),
      params: { wake_at: wake_at, timezone: "America/New_York" }, as: :json

    assert_response :success
    condition = Trigger.find(JSON.parse(response.body)["trigger_id"]).trigger_conditions.sole
    assert_equal wake_at, condition.scheduled_at
    assert_equal "America/New_York", condition.schedule_timezone
  end

  test "a running session is marked pending_sleep and says so" do
    session = sessions(:running)

    post pause_until_session_url(session), params: { wake_at: future_wake_at }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body["pending_sleep"]
    assert_equal "running", body["status"]
    assert_equal true, session.reload.metadata["pending_sleep"]
  end

  test "rejects a past wake_at without creating a trigger or changing session state" do
    session = sessions(:needs_input)

    assert_no_difference "Trigger.count" do
      post pause_until_session_url(session), params: { wake_at: future_wake_at(-1.hour) }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match "already passed", JSON.parse(response.body)["error"]
    assert session.reload.needs_input?
  end

  test "rejects a wake_at inside the grace window" do
    post pause_until_session_url(sessions(:needs_input)), params: { wake_at: future_wake_at(10.seconds) }, as: :json

    assert_response :unprocessable_entity
    assert_match "Pick a later time", JSON.parse(response.body)["error"]
  end

  test "rejects an unparseable wake_at" do
    assert_no_difference "Trigger.count" do
      post pause_until_session_url(sessions(:needs_input)), params: { wake_at: "next tuesday" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match "ISO-8601", JSON.parse(response.body)["error"]
  end

  test "refuses a session whose state the auto-sleep would silently no-op" do
    assert_no_difference "Trigger.count" do
      post pause_until_session_url(sessions(:archived)), params: { wake_at: future_wake_at }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match "cannot be paused from here", JSON.parse(response.body)["error"]
  end

  test "the HTML fallback redirects with a flash instead of rendering JSON" do
    post pause_until_session_url(sessions(:needs_input)), params: { wake_at: future_wake_at(-1.hour) }

    assert_redirected_to session_path(sessions(:needs_input))
    assert_match "already passed", flash[:alert]
  end
  test "picking a second time replaces the first rather than arming two wakes" do
    session = sessions(:needs_input)
    # The first pause moves it to `waiting`, where pausable_until? starts asking
    # whether it ever ran. A session in needs_input has, by definition.
    session.update_columns(session_id: SecureRandom.uuid)

    post pause_until_session_url(session), params: { wake_at: future_wake_at(1.hour) }, as: :json
    first_id = JSON.parse(response.body)["trigger_id"]

    assert_no_difference "Trigger.count" do
      post pause_until_session_url(session), params: { wake_at: future_wake_at(3.hours) }, as: :json
    end

    assert_response :success
    assert_not Trigger.exists?(first_id), "the replaced wake would still fire an hour early"
    assert Trigger.exists?(JSON.parse(response.body)["trigger_id"])
  end
  test "refuses a waiting session that has never started" do
    queued = sessions(:waiting)
    assert_nil queued.session_id, "a queued-for-spawn session has never been issued one"

    assert_no_difference "Trigger.count" do
      post pause_until_session_url(queued), params: { wake_at: future_wake_at }, as: :json
    end

    # `waiting` is also the AASM initial state. A session queued for spawn is not
    # asleep: the auto-sleep no-ops, `start` does not consume the wake, and the
    # operator would be told it is paused while it starts anyway.
    assert_response :unprocessable_entity
    assert_match "cannot be paused from here", JSON.parse(response.body)["error"]
  end

  test "still accepts a waiting session that has started" do
    sleeping = sessions(:waiting)
    sleeping.update_columns(session_id: SecureRandom.uuid)

    assert_difference "Trigger.count", 1 do
      post pause_until_session_url(sleeping), params: { wake_at: future_wake_at }, as: :json
    end

    assert_response :success
  end
end
