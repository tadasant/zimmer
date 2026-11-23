# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# A session that arms a wake and ends its turn sleeps, whichever order the arming
# and the job's `start!` landed in.
#
# AgentSessionJob records `start!` after the runtime process is spawned, so a live
# agent acts against a `waiting` row until that write lands. Session 30564 armed
# two wakes there, ended its turn before `start!`, and rested in `needs_input` on
# the human's action queue with both wakes armed.
#
# `on_a_worker!` is what makes the row an in-flight turn: a `waiting` session with
# no such job really is dormant.
class Sessions::WakeArmedBeforeStartTest < ActionDispatch::IntegrationTest
  setup do
    GoodJob::Job.where(job_class: "AgentSessionJob").delete_all
    GoodJob::Process.delete_all
    @session = sessions(:needs_input)
    @session.update_columns(status: Session.statuses[:waiting], metadata: {}, session_id: SecureRandom.uuid)
    @session.reload
  end

  teardown { GoodJob::Process.delete_all }

  # A turn a live GoodJob capsule is executing.
  def on_a_worker!(session = @session)
    process = GoodJob::Process.create!(state: { "hostname" => "worker-1" })
    GoodJob::Job.create!(
      active_job_id: SecureRandom.uuid, queue_name: "agents", job_class: "AgentSessionJob",
      serialized_params: { "arguments" => [ session.id ] }, scheduled_at: 1.minute.ago,
      performed_at: 1.minute.ago, locked_at: 1.minute.ago, locked_by_id: process.id
    )
  end

  def schedule_wake(at: 90.minutes.from_now)
    Sessions::ScheduleWakeUp.call(
      session: @session, wake_at: at.utc.strftime("%Y-%m-%dT%H:%M:%S"), prompt: "Backstop", timezone: "UTC"
    )
  end

  def watch(watched = sessions(:running))
    Trigger.create!(
      name: "Watch session #{watched.id}", agent_root_name: @session.agent_runtime, prompt_template: "it moved",
      reuse_session: true, last_session_id: @session.id,
      trigger_conditions_attributes: [ {
        condition_type: "ao_event",
        configuration: { "event_name" => "session_archived", "watched_session_id" => watched.id }
      } ]
    )
  end

  def self_tool
    Mcp::Tools::SelfSessionActionSession.new(context: Mcp::Context.new(tool_groups: "self_session"))
  end

  # Both the writes of AgentSessionJob's own instance and of the request that armed
  # the wake happen in other processes, so each side reloads.
  def finish_turn!
    @session.reload.start!
    @session.reload.pause!
    @session.reload
  end

  def log_lines = @session.logs.reload.pluck(:content)

  # === The reported interleaving ===

  test "wakes armed while the process is live and the row is still waiting end the turn asleep" do
    on_a_worker!
    watcher = watch
    backstop = schedule_wake

    finish_turn!

    assert @session.waiting?, "a session holding only a machine wait is not on the action queue"
    assert_includes log_lines, "[Trigger##{watcher.id}] pending_sleep set — session will transition to waiting after current turn"
    assert_nil @session.metadata["pending_sleep"]
    assert_equal %w[enabled enabled], [ watcher, backstop ].map { |t| t.reload.status }
  end

  test "a watcher alone armed in that window ends the turn asleep" do
    on_a_worker!
    watch

    assert finish_turn!.waiting?
  end

  test "a wake armed in that window is not stamped over a platform dormancy" do
    on_a_worker!
    @session.merge_metadata!(Sessions::StopRecord.pending_sleep(Sessions::StopRecord::SPOT_PAUSE))
    schedule_wake

    assert_equal Sessions::StopRecord::SPOT_PAUSE, @session.reload.metadata[Sessions::StopRecord::PENDING_SLEEP_REASON]
  end

  test "a wake armed on a session asleep with no turn leaves no mark, and says so on the timeline" do
    trigger = schedule_wake

    assert_nil @session.reload.metadata["pending_sleep"]
    assert_includes log_lines, "[Trigger##{trigger.id}] No auto-sleep to arrange — the session is waiting with no turn in progress"
  end

  # === The turn-end derivation: no mark at all ===

  test "a turn that ends unmarked with its own schedule armed sleeps on it and says why" do
    trigger = schedule_wake
    @session.reload.start!
    assert_nil @session.metadata["pending_sleep"]

    @session.pause!

    assert @session.reload.waiting?
    assert_equal Sessions::StopRecord::SCHEDULED_WAKE, @session.metadata[Sessions::StopRecord::REASON]
    assert log_lines.any? { |line| line.start_with?("[Trigger##{trigger.id}] This turn ended with no sleep arranged") }
  end

  # AgentSessionJob re-fires resume when the row moved during spawn, which clears the mark.
  test "a mark cleared by a resume between the arming and start is derived again" do
    on_a_worker!
    schedule_wake
    @session.reload.remove_metadata!(SessionStateMachine::PENDING_SLEEP_KEYS)

    assert finish_turn!.waiting?
  end

  test "an unmarked turn with only a watcher armed rests in needs_input (#648)" do
    watch

    assert finish_turn!.needs_input?
  end

  test "an unmarked turn with nothing armed rests in needs_input" do
    assert finish_turn!.needs_input?
  end

  test "a schedule that can no longer fire does not justify a sleep (#1172)" do
    trigger = schedule_wake
    condition = trigger.trigger_conditions.first
    condition.update_columns(
      configuration: condition.configuration.merge(
        "scheduled_at" => (SessionStateMachine::SCHEDULE_FIRE_SETTLE + 5.minutes).ago.utc.strftime("%Y-%m-%dT%H:%M:%S")
      )
    )

    assert finish_turn!.needs_input?
  end

  test "a wake held from the wait that just ended is retired, not slept on (#1172)" do
    trigger = schedule_wake
    trigger.update_columns(wake_held_at: Time.current)

    assert finish_turn!.needs_input?
    assert_not Trigger.exists?(trigger.id)
  end

  test "a schedule kept beside a held group still puts the session back to sleep (#1325)" do
    held = schedule_wake
    held.update_columns(wake_held_at: Time.current)
    kept = schedule_wake(at: 3.hours.from_now)

    assert finish_turn!.waiting?
    assert_equal [ kept.id ], Trigger.where(last_session_id: @session.id).pluck(:id)
  end

  %w[user recovery mcp_retry].each do |paused_by|
    test "a #{paused_by} pause with a schedule armed stays in needs_input" do
      schedule_wake
      @session.reload.start!
      @session.merge_metadata!("paused_by" => paused_by)
      @session.pause!

      assert @session.reload.needs_input?
    end
  end

  test "a turn parked undelivered stays in needs_input" do
    schedule_wake
    @session.reload.start!
    @session.merge_metadata!("failure_reason" => Sessions::ParkUndeliveredTurn::FAILURE_REASON)
    @session.pause!

    assert @session.reload.needs_input?
  end

  test "a status-summary fork is not slept" do
    schedule_wake
    @session.reload.start!
    @session.merge_metadata!(SessionStatusSummaryGenerator::FORK_MARKER => 1)
    @session.pause!

    assert @session.reload.needs_input?
  end

  test "a hand-back this instance has not read yet still rests in needs_input" do
    schedule_wake
    @session.reload.start!
    Session.find(@session.id).merge_metadata!(
      SessionStateMachine::HANDED_BACK_TO_HUMAN => Time.current.utc.iso8601(6)
    )
    @session.pause!

    assert @session.reload.needs_input?
  end

  test "a mark this instance has not read yet is still executed" do
    watch
    @session.reload.start!
    Session.find(@session.id).merge_metadata!(Sessions::StopRecord.pending_sleep(Sessions::StopRecord::SCHEDULED_WAKE))
    @session.pause!

    assert @session.reload.waiting?
  end

  test "a failure while deriving leaves the pause standing" do
    schedule_wake
    @session.reload.start!
    Session.any_instance.stubs(:pending_one_time_wake_conditions).raises(ActiveRecord::StatementInvalid, "boom")
    @session.pause!

    assert @session.reload.needs_input?
  end

  # === Sibling surfaces in the same window ===

  test "rest_in_needs_input in the window beats the wakes armed before it" do
    on_a_worker!
    trigger = schedule_wake
    result = self_tool.call("action" => "rest_in_needs_input", "session_id" => @session.id)

    assert_includes result, "## Resting In Needs Input"
    assert finish_turn!.needs_input?
    assert trigger.reload.enabled?
  end

  test "a wake armed in the window after a hand-back puts the session back to sleep" do
    on_a_worker!
    self_tool.call("action" => "rest_in_needs_input", "session_id" => @session.id)
    schedule_wake

    assert finish_turn!.waiting?
  end

  test "rest_in_needs_input is still refused on a session asleep with no turn" do
    error = assert_raises(Mcp::ToolError) do
      self_tool.call("action" => "rest_in_needs_input", "session_id" => @session.id)
    end
    assert_includes error.message, "not in a turn"
  end

  test "a spot-queue park in the window sleeps the session at its turn end" do
    on_a_worker!
    result = Sessions::PauseIntoSpotQueue.call(session: @session)

    assert result.pending_sleep
    assert finish_turn!.waiting?
  end

  test "the sleep endpoint defers in the window and refuses a dormant session" do
    ENV["API_KEYS"] = "wake-window-key"
    headers = { "X-API-Key" => "wake-window-key" }
    post sleep_api_v1_session_path(@session), headers: headers
    assert_response :unprocessable_entity

    on_a_worker!
    post sleep_api_v1_session_path(@session), headers: headers
    assert_response :success
    assert finish_turn!.waiting?
  ensure
    ENV.delete("API_KEYS")
  end
end
