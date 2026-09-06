# frozen_string_literal: true

require "test_helper"

# The strand of https://github.com/tadasant/zimmer/issues/898, walked end to end.
#
# A session schedules its own `wake_me_up_later`, somebody else follows it up
# before that wake is due, and the session comes to rest. Until this test passed,
# the resume consumed the wake on the way through: the session took its turn,
# paused into `needs_input` — the correct thing for it to do — and sat there with
# nothing scheduled to bring it back and no way to find out. Session 13403 spent
# the morning of 2026-09-04 like that, holding a nearly-finished PR, until an
# unrelated third session happened to nudge it.
#
# These go through the real surfaces (Sessions::ScheduleWakeUp, the MCP tool, the
# REST controller, the queue drain) rather than poking the flag, because the flag
# is not the thing that broke — the wiring at each entry point is.
class Sessions::WakeSurvivesFollowUpTest < ActionDispatch::IntegrationTest
  setup { ENV["API_KEYS"] = "test_api_key_12345" }
  teardown { ENV.delete("API_KEYS") }

  # A wake scheduled the way an agent schedules one: through the service the
  # `wake_me_up_later` tool wraps, which also puts the session to sleep.
  def schedule_wake(session, at: 30.minutes.from_now)
    trigger = Sessions::ScheduleWakeUp.call(
      session: session,
      wake_at: at.utc.strftime("%Y-%m-%dT%H:%M:%S"),
      prompt: "Re-run the foreground CI watch on #269 and apply `ready to merge` once green",
      timezone: "UTC"
    )
    [ trigger, trigger.trigger_conditions.first ]
  end

  def follow_up_over_mcp(session, prompt: "Also check whether the base branch moved")
    Mcp::Tools::ActionSession
      .new(context: Mcp::Context.new(tool_groups: "sessions"))
      .call("action" => "follow_up", "session_id" => session.id, "prompt" => prompt)
  end

  # THE REGRESSION TEST. The whole sequence, in order, with the assertion at the
  # end that the session still has something coming for it.
  test "a self-scheduled wake survives another session's follow_up and the rest that follows it" do
    session = sessions(:needs_input)
    trigger, condition = schedule_wake(session)

    assert session.reload.waiting?, "scheduling a wake puts the session to sleep"

    follow_up_over_mcp(session)
    assert session.reload.running?, "the follow-up takes the session's next turn"

    session.pause!

    assert session.reload.needs_input?, "the followed-up turn comes to rest, which is correct"
    assert_nil condition.reload.last_triggered_at,
      "the follow-up must not consume the wake the session is still counting on"
    assert_equal "enabled", trigger.reload.status
    assert session.reload.awaiting_scheduled_wake?,
      "a session at rest after a follow-up must still have its own wake armed to collect it"
  end

  # The same session, one turn later: the wake it kept is the wake that fires, and
  # it resumes the session exactly as the session intended. The fire then behaves
  # like any other wake fire — held across the woken turn (#569), retired when
  # that turn comes to rest.
  test "the preserved wake still fires, resumes the session, and is spent by doing so" do
    session = sessions(:needs_input)
    trigger, _condition = schedule_wake(session)
    follow_up_over_mcp(session)
    session.reload.pause!

    trigger.send(:follow_up_session!, session.reload, prompt: "Wake up")

    assert_equal :delivered, trigger.last_follow_up_status
    assert session.reload.running?, "the wake the follow-up left alone is the wake that wakes the session"
    assert_not_nil trigger.reload.wake_held_at, "and it is held across the turn it woke, not consumed at fire time"

    session.reload.pause!

    assert_not Trigger.exists?(trigger.id), "the turn it woke came to rest, so the wake is retired"
  end

  # The delivery route does not change the answer. A follow-up sent to a busy
  # session is queued and drains at the next turn boundary; that drain is the same
  # event as a direct follow-up and must not eat the wake either.
  test "a wake survives a follow_up that arrives while the session is running and drains later" do
    # The shape session 13403 was actually in: still running its turn when it
    # scheduled the wake, so the sleep is deferred to the end of that turn, and
    # the router's follow-up lands in the queue rather than being delivered.
    session = sessions(:running)
    _trigger, condition = schedule_wake(session)
    assert session.reload.running?
    assert_equal true, session.metadata["pending_sleep"]

    follow_up_over_mcp(session)
    assert_equal 1, session.enqueued_messages.pending.count, "a follow-up to a busy session queues"

    session.reload.pause!
    assert session.reload.waiting?, "the turn ends and the deferred sleep takes effect"

    EnqueuedMessageProcessorService.new(session.reload).process_next_message

    assert session.reload.running?, "the queued message takes the session's next turn"
    assert_nil condition.reload.last_triggered_at,
      "a queued follow-up draining is still a follow-up — it must not consume the wake"
  end

  # The REST door, and the caller-facing half: the sender is told the session it
  # just redirected still wakes itself, so it does not assume it has taken on
  # responsibility for that.
  test "the REST follow_up preserves the wake and names it in the response" do
    session = sessions(:needs_input)
    _trigger, condition = schedule_wake(session)

    post follow_up_api_v1_session_path(session.reload),
      params: { prompt: "Also check the base branch" },
      headers: { "X-API-Key" => "test_api_key_12345" }

    assert_response :success
    body = JSON.parse(response.body)
    assert_nil condition.reload.last_triggered_at
    assert_equal true, body.dig("pending_wake", "preserved")
    assert_equal condition.scheduled_at_time.utc.iso8601, body.dig("pending_wake", "at")
  end

  test "the MCP follow_up result names the wake it preserved" do
    session = sessions(:needs_input)
    _trigger, condition = schedule_wake(session)

    result = follow_up_over_mcp(session)

    assert_includes result, "- **Its own wake-up:** still armed for #{condition.scheduled_at_time.utc.iso8601}"
    assert_includes result, "did not cancel it"
  end

  # `Session#deliver_follow_up!` is the one shared delivery path behind the web
  # UI's follow-up form, the GitHub comment evaluator, `message_parent`, the
  # heartbeat sweep and every non-wake trigger. Asserting on it here is what
  # covers all of them at the seam they share.
  test "the shared follow-up delivery path preserves the wake" do
    session = sessions(:needs_input)
    session.update!(session_id: "conversation-to-resume")
    _trigger, condition = schedule_wake(session)

    session.reload.deliver_follow_up!("A human typed this into the session page")

    assert session.reload.running?
    assert_nil condition.reload.last_triggered_at,
      "a follow-up through the shared path must not consume the wake either"
  end

  # A trigger that is not a wake — a Slack feed, a recurring schedule, a GitHub
  # poller — fires INTO a session rather than being the thing it was waiting for.
  # That is a follow-up, and it takes the preserving branch rather than the
  # wake-fire hold branch.
  test "a non-wake trigger firing into a sleeping session preserves that session's own wake" do
    session = sessions(:needs_input)
    session.update!(session_id: "conversation-to-resume")
    _wake, condition = schedule_wake(session)

    poller = Trigger.create!(
      name: "Slack feed",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Someone mentioned you",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "unit" => "hours", "interval" => 1, "timezone" => "UTC" } }
      ]
    )
    assert_not poller.one_time_reuse_trigger?, "this test is only meaningful for a non-wake trigger"

    poller.send(:follow_up_session!, session.reload, prompt: "Someone mentioned you")

    assert session.reload.running?
    assert_nil condition.reload.last_triggered_at,
      "a poller's prompt is a follow-up, not the wake this session was waiting for"
  end

  # The layer below the resume, and the one that used to drop the wake anyway. A
  # follow-up delivered to a sleeping session resumes it and enqueues the job;
  # the spot gate can defer that turn and return the session to `waiting` carrying
  # the same prompt, and the re-check job re-resumes it here.
  test "re-resuming to deliver a deferred follow-up preserves the wake" do
    session = sessions(:needs_input)
    _trigger, condition = schedule_wake(session)

    AgentSessionJob.new.send(:resume_for_recovery_prompt, session.reload, "The deferred follow-up")

    assert session.reload.running?
    assert_nil condition.reload.last_triggered_at,
      "the re-check must not consume the wake the resume above deliberately kept"
  end

  # The line the change deliberately does NOT cross. A restart replaces the wait
  # rather than adding to it, so it still consumes — and the pause guard that
  # stands in front of it still stands.
  test "a restart of a session whose wake has come due still consumes that wake" do
    session = sessions(:needs_input)
    session.update!(session_id: "conversation-to-resume")
    _trigger, condition = schedule_wake(session)
    # Past its moment, so `refuse_if_paused!` no longer holds the restart off and
    # the consuming branch is reached.
    condition.update!(configuration: condition.configuration.merge("scheduled_at" => 2.minutes.ago.utc.iso8601))

    Mcp::Tools::ActionSession
      .new(context: Mcp::Context.new(tool_groups: "sessions"))
      .call("action" => "restart", "session_id" => session.reload.id)

    assert_not_nil condition.reload.last_triggered_at,
      "a restart is a takeover: the wait it replaces is over, so the wake is consumed"
  end

  # The hazard preserving might have introduced, and why it does not. A wake that
  # outlives its session cannot resuscitate it: resuscitation needs
  # `resuscitate_archived`, which Sessions::ScheduleWakeUp never sets, so the fire
  # skips silently — and CleanupStaleTriggersJob destroys the row on its own sweep,
  # which is the one place that honours the `resuscitate_archived` opt-in.
  test "a wake that outlives its archived session skips rather than resuscitating it" do
    session = sessions(:needs_input)
    trigger, _condition = schedule_wake(session)
    follow_up_over_mcp(session)
    session.reload.pause!
    session.reload.archive!

    assert_not trigger.reload.resuscitate_archived,
      "a wake_me_up_later trigger must not opt into waking archived sessions"

    trigger.send(:create_session!, prompt: "Wake up")

    assert session.reload.archived?, "the fire must leave the archived session alone"
  end

  # And the sweep that does collect it excludes exactly the triggers that asked to
  # wake an archived session, which is why the preserve branch does not retire
  # anything itself.
  test "the stale-trigger sweep collects a wake whose session archived" do
    session = sessions(:needs_input)
    trigger, _condition = schedule_wake(session)
    follow_up_over_mcp(session)
    session.reload.pause!
    session.reload.archive!

    CleanupStaleTriggersJob.new.perform

    assert_not Trigger.exists?(trigger.id),
      "a one-time wake whose target archived is the sweep's to destroy"
  end
end
