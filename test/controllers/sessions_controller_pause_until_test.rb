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

  # The bug this file's running-session cases exist for: the control used to arm a
  # wake, mark the session `pending_sleep`, and leave it running. An agent turn
  # lasts minutes or hours, so from the operator's chair nothing happened at all.
  test "a running session is stopped and asleep by the time the request returns" do
    session = sessions(:running)

    post pause_until_session_url(session), params: { wake_at: future_wake_at }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body["halted_turn"], "the turn should have been stopped"
    assert_equal "waiting", body["status"]
    assert session.reload.waiting?
    # Consumed by execute_pending_sleep on the way through needs_input, not left
    # behind to surprise-sleep the session after some later turn.
    assert_nil session.metadata["pending_sleep"]
    assert_not body["pending_sleep"]
  end

  test "halting a running session leaves the wake armed and deliverable" do
    session = sessions(:running)

    post pause_until_session_url(session), params: { wake_at: future_wake_at }, as: :json

    trigger = Trigger.find(JSON.parse(response.body)["trigger_id"])
    assert trigger.enabled?
    assert_equal session.id, trigger.last_session_id
    assert trigger.reuse_session
    # The marker that would make Trigger#reusable_session? drop the wake on
    # arrival. A Pause Until is not "a human took this session over".
    assert_not_equal "user", session.reload.metadata["paused_by"]
    assert session.paused_until_scheduled_time?
  end

  # The degraded path is still the old one: if the halt cannot land, the session
  # keeps its pending_sleep and sleeps when the turn ends rather than staying
  # awake with a wake armed and nothing to trip it.
  test "a running session whose turn cannot be stopped falls back to sleeping at turn end" do
    session = sessions(:running)
    Sessions::HaltRunningTurn.stub(:call, Sessions::HaltRunningTurn::Result.new(halted: false, reason: :could_not_pause)) do
      post pause_until_session_url(session), params: { wake_at: future_wake_at }, as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_not body["halted_turn"]
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
  # --- Spot Queue: the choice in the same panel that is not a time ------------

  test "the spot queue mode sleeps the session and arms nothing at all" do
    session = sessions(:needs_input)

    assert_no_difference "Trigger.count", "the whole point: no wake trigger is created" do
      post pause_until_session_url(session), params: { mode: "spot_queue" }, as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert body["spot_queue"]
    assert_equal "waiting", body["status"]
    assert_not body["pending_sleep"]

    session.reload
    assert session.waiting?
    assert SpotSessionPause.queued_by_user?(session)
    assert_not session.awaiting_scheduled_wake?
  end

  test "the spot queue mode pins a priority session to spot and says so" do
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::PRIORITY)

    post pause_until_session_url(session), params: { mode: "spot_queue" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body["pinned_to_spot"]
    assert_equal session.precedence, body["precedence"]
    assert session.reload.spot?
  end

  test "a running session is stopped and in the spot queue by the time the request returns" do
    session = sessions(:running)

    post pause_until_session_url(session), params: { mode: "spot_queue" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body["halted_turn"], "the turn should have been stopped"
    assert_not body["pending_sleep"]
    assert_equal "waiting", body["status"]
    assert session.reload.waiting?
    assert_nil session.metadata["pending_sleep"]
    assert SpotSessionPause.paused?(session)
  end

  test "the spot queue mode carries the panel's resume prompt" do
    post pause_until_session_url(sessions(:needs_input)),
      params: { mode: "spot_queue", prompt: "Re-check the deploy" }, as: :json

    assert_equal "Re-check the deploy",
      sessions(:needs_input).reload.metadata[SpotSessionPause::QUEUED_PROMPT]
  end

  # The same gate the time presets get, before the mode is even read.
  test "the spot queue mode refuses a session that cannot be paused from here" do
    post pause_until_session_url(sessions(:archived)), params: { mode: "spot_queue" }, as: :json

    assert_response :unprocessable_entity
    assert_match "cannot be paused from here", JSON.parse(response.body)["error"]
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
