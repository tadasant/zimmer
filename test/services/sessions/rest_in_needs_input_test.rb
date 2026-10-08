# frozen_string_literal: true

require "test_helper"

# A session handing back to a human while a wake of its own is armed.
#
# Each re-sleep below is one a session can be in when the turn that needs the
# human ends, and without this action each one puts it in `waiting` — off the
# homepage action queue — until the wake fires. Session 20141 hit the system-recovery one on
# 2026-10-08 and armed a dummy wake to get out of it; 19775 hit the
# scheduled-wake one and was hidden for hours.
#
# Integration test so the follow-up path runs through the real MCP surfaces, as
# Sessions::WakeSurvivesFollowUpTest does for the shape this must not regress.
class Sessions::RestInNeedsInputTest < ActionDispatch::IntegrationTest
  def schedule_wake(session, at: 90.minutes.from_now)
    Sessions::ScheduleWakeUp.call(
      session: session,
      wake_at: at.utc.strftime("%Y-%m-%dT%H:%M:%S"),
      prompt: "Backstop: check on the fix session",
      timezone: "UTC"
    )
  end

  def watch(session, watched)
    Trigger.create!(
      name: "Watch session #{watched.id}",
      agent_root_name: session.agent_runtime,
      prompt_template: "it moved",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [ {
        condition_type: "ao_event",
        configuration: { "event_name" => "session_archived", "watched_session_id" => watched.id }
      } ]
    )
  end

  def self_tool
    Mcp::Tools::SelfSessionActionSession.new(context: Mcp::Context.new(tool_groups: "self_session"))
  end

  def follow_up_over_mcp(session, prompt: "Did the pairing fix land?")
    Mcp::Tools::ActionSession
      .new(context: Mcp::Context.new(tool_groups: "sessions"))
      .call("action" => "follow_up", "session_id" => session.id, "prompt" => prompt)
  end

  # The shape #1212 must keep: a follow-up answered with a backstop armed goes
  # back to sleep. Here as the control for the test after it.
  test "without the action, a followed-up session goes back to sleep on its backstop" do
    session = sessions(:needs_input)
    schedule_wake(session)
    follow_up_over_mcp(session)
    session.reload.start!
    session.pause!

    assert session.reload.waiting?
  end

  test "a followed-up session that needs the human rests in needs_input with its backstop still armed" do
    session = sessions(:needs_input)
    trigger = schedule_wake(session)
    follow_up_over_mcp(session)
    session.reload.start!

    result = self_tool.call("action" => "rest_in_needs_input", "session_id" => session.id)

    assert_includes result, "## Resting In Needs Input"
    assert_includes result, "follow_up_resleep"
    assert_includes result, "still armed"

    session.reload.pause!

    assert session.reload.needs_input?, "a hand-back must land on the action queue"
    assert Trigger.exists?(trigger.id), "the backstop is kept unless the caller cancels it"
    assert session.armed_one_time_wake?

    trigger.reload.send(:follow_up_session!, session.reload, prompt: "Backstop: check on the fix session")
    assert_equal :delivered, trigger.last_follow_up_status, "the kept backstop still resumes the session if it fires first"
  end

  # 20141 at 05:46Z: a recovery resume preserved its 07:30Z backstop and marked
  # the turn to go back to sleep on it.
  test "drops a system-recovery re-sleep" do
    session = sessions(:needs_input)
    schedule_wake(session)
    session.reload.resume_for_system_recovery!
    assert_equal Sessions::StopRecord::SYSTEM_RECOVERY_RESLEEP,
      session.reload.metadata[Sessions::StopRecord::PENDING_SLEEP_REASON]
    session.start!

    Sessions::RestInNeedsInput.call(session: session.reload)
    session.reload.pause!

    assert session.reload.needs_input?
  end

  # 19775: armed a watcher and a backstop in the same turn that asked the human
  # to approve something.
  test "drops the scheduled-wake sleep a running session writes when it arms a wake" do
    session = sessions(:running)
    schedule_wake(session)
    watch(session, sessions(:waiting))
    assert_equal Sessions::StopRecord::SCHEDULED_WAKE,
      session.reload.metadata[Sessions::StopRecord::PENDING_SLEEP_REASON]

    result = Sessions::RestInNeedsInput.call(session: session)
    session.reload.pause!

    assert session.reload.needs_input?
    assert_equal Sessions::StopRecord::SCHEDULED_WAKE, result.dropped_sleep_reason
    assert result.wakes_still_armed
    assert_empty result.cancelled_trigger_ids
  end

  test "cancel_wakes destroys this session's schedules and watchers and nothing else" do
    session = sessions(:running)
    backstop = schedule_wake(session)
    watcher = watch(session, sessions(:waiting))
    other = schedule_wake(sessions(:needs_input))
    mixed = Trigger.create!(
      name: "Nightly sweep with a one-off",
      agent_root_name: session.agent_runtime,
      prompt_template: "sweep",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 2.hours.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S"), "timezone" => "UTC" } },
        { condition_type: "schedule", configuration: { "unit" => "hours", "interval" => 6, "timezone" => "UTC" } }
      ]
    )

    result = Sessions::RestInNeedsInput.call(session: session.reload, cancel_wakes: true)
    session.reload.pause!

    assert_equal [ backstop.id, watcher.id ].sort, result.cancelled_trigger_ids.sort
    assert result.wakes_still_armed, "the mixed trigger's one-off can still wake the session, and the result says so"
    assert Trigger.exists?(other.id), "another session's wake is not this one's to cancel"
    assert Trigger.exists?(mixed.id), "a trigger doing other work is not a wake"
    assert session.reload.needs_input?
  end

  test "with cancel_wakes and nothing else armed, only a message resumes it" do
    session = sessions(:running)
    schedule_wake(session)

    result = self_tool.call("action" => "rest_in_needs_input", "session_id" => session.id, "cancel_wakes" => true)
    session.reload.pause!

    assert_includes result, "none armed"
    assert session.reload.needs_input?
    assert_not session.armed_one_time_wake?
  end

  test "leaves an unconditional sleep intent alone and says so" do
    session = sessions(:running)
    session.merge_metadata!(Sessions::StopRecord.pending_sleep(Sessions::StopRecord::DELIBERATE_SLEEP))

    result = Sessions::RestInNeedsInput.call(session: session)
    session.reload.pause!

    assert_equal Sessions::StopRecord::DELIBERATE_SLEEP, result.unconditional_sleep_reason
    assert_nil result.dropped_sleep_reason
    assert session.reload.waiting?
  end

  # --- The hand-back lasts until the session waits again ---------------------

  test "a deploy interrupting the turn after the call does not put it back to sleep" do
    session = sessions(:running)
    schedule_wake(session)
    Sessions::RestInNeedsInput.call(session: session)

    # The turn dies before its pause and recovery resumes it.
    session.reload.update!(status: "needs_input")
    session.resume_for_system_recovery!
    assert_nil session.reload.metadata["pending_sleep"], "recovery must not write a re-sleep over a hand-back"
    session.start!
    session.pause!

    assert session.reload.needs_input?
    assert session.armed_one_time_wake?, "the backstop is still kept"
  end

  test "a later follow-up does not bury the hand-back under a re-sleep" do
    session = sessions(:running)
    schedule_wake(session)
    Sessions::RestInNeedsInput.call(session: session)
    session.reload.pause!
    assert session.reload.needs_input?

    follow_up_over_mcp(session, prompt: "Router: any update?")
    session.reload.start!
    session.pause!

    assert session.reload.needs_input?, "the question to the human is still the session's last word"
  end

  test "a follow-up queued during the turn drains without re-sleeping it" do
    session = sessions(:running)
    schedule_wake(session)
    follow_up_over_mcp(session, prompt: "Slack: are you there?")
    Sessions::RestInNeedsInput.call(session: session.reload)

    EnqueuedMessageProcessorService.new(session.reload).process_next_message
    session.reload
    session.start! if session.may_start?
    session.reload.pause! if session.running?

    assert session.reload.needs_input?
  end

  test "arming a new wake ends the hand-back, and the session sleeps on it" do
    session = sessions(:running)
    schedule_wake(session)
    Sessions::RestInNeedsInput.call(session: session)
    session.reload.pause!
    assert session.reload.handed_back_to_human?

    schedule_wake(session.reload, at: 30.minutes.from_now)

    assert session.reload.waiting?
    assert_not session.handed_back_to_human?

    follow_up_over_mcp(session)
    session.reload.start!
    session.pause!
    assert session.reload.waiting?, "with the hand-back over, #1212's re-sleep applies again"
  end

  test "a group a wake fired into this turn does not count as still armed" do
    session = sessions(:needs_input)
    trigger = schedule_wake(session)
    trigger.send(:follow_up_session!, session.reload, prompt: "Backstop")
    session.reload.start!
    assert_not_nil trigger.reload.wake_held_at

    result = Sessions::RestInNeedsInput.call(session: session.reload)

    assert_not result.wakes_still_armed, "the held group is retired at this turn's pause"
  end

  test "cancel_wakes given as the string false cancels nothing" do
    session = sessions(:running)
    trigger = schedule_wake(session)

    self_tool.call("action" => "rest_in_needs_input", "session_id" => session.id, "cancel_wakes" => "false")

    assert Trigger.exists?(trigger.id)
  end

  test "refuses a session that is asleep" do
    session = sessions(:needs_input)
    trigger = schedule_wake(session)
    assert session.reload.waiting?

    error = assert_raises(Mcp::ToolError) do
      self_tool.call("action" => "rest_in_needs_input", "session_id" => session.id, "cancel_wakes" => true)
    end

    assert_match(/is waiting, not in a turn/, error.message)
    assert Trigger.exists?(trigger.id), "a refused call cancels nothing"
  end
end
