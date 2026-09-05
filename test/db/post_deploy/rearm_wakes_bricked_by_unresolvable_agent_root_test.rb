# frozen_string_literal: true

require "test_helper"

# The retroactive half of https://github.com/tadasant/zimmer/issues/600: #834
# stopped NEW wakes bricking themselves on an unresolvable agent root, and this
# task re-arms the ones that were already parked `failed` when it merged.
#
# The predicate is tested from both sides deliberately. Too broad wakes sessions
# that were meant to stay asleep; too narrow leaves them asleep with nobody the
# wiser. Both failures are silent, so neither shows up unless a test asks.
class RearmWakesBrickedByUnresolvableAgentRootTest < ActiveSupport::TestCase
  # Verbatim shape of what Trigger#format_last_error stores: "#{e.class}: #{e.message}".
  BRICKED_ERROR = AgentRootsConfig::AgentRootNotFoundError.new(
    "Agent root 'claude_code' not found in catalog and no successor could be identified"
  )

  setup do
    @entry = PostDeployTask::Registry.find("20260904120000")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
  end

  # --- fixtures built by hand ------------------------------------------------

  def a_session(status: :waiting, **attrs)
    Session.create!(
      prompt: "sleeper #{SecureRandom.hex(4)}",
      agent_runtime: "claude_code",
      status: status,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      **attrs
    )
  end

  # A per-session wake exactly as Sessions::ScheduleWakeUp builds one, including
  # the `agent_root_name` fallback that caused #600.
  def wake_trigger(session:, scheduled_at: 2.hours.ago, agent_root_name: "claude_code")
    Trigger.create!(
      name: "Wake session ##{session.id}",
      agent_root_name: agent_root_name,
      prompt_template: "time to wake up",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [ {
        condition_type: "schedule",
        configuration: { "scheduled_at" => scheduled_at.utc.strftime("%Y-%m-%dT%H:%M:%S"), "timezone" => "UTC" }
      } ]
    )
  end

  # The other one-shot shape: Mcp::Tools::WakeMeUpWhenSessionChangesState's watcher.
  def ao_event_wake_trigger(session:, watched:, event_name: "session_archived")
    Trigger.create!(
      name: "Wake session ##{session.id} when #{watched.id} is #{event_name}",
      agent_root_name: "claude_code",
      prompt_template: "the session you watched changed state",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [ {
        condition_type: "ao_event",
        configuration: { "event_name" => event_name, "watched_session_id" => watched.id.to_s }
      } ]
    )
  end

  def brick!(trigger, error = BRICKED_ERROR)
    assert trigger.mark_failed(error), "mark_failed must persist"
    trigger.reload
  end

  def run_task
    run = PostDeployTaskRun.ledger_for(@entry)
    assert run.claim!(owner: "test"), "the ledger row must be claimable"
    outcome = @task_class.new(run: run, logger: Rails.logger).up
    [ run.reload, outcome ]
  end

  # --- the rows that MUST be re-armed ---------------------------------------

  test "re-arms a bricked one-time schedule wake whose session is still waiting" do
    session = a_session
    trigger = brick!(wake_trigger(session: session))
    assert_equal "waiting", session.reload.status

    run, outcome = run_task

    assert_nil outcome, "a task that finishes returns something other than CONTINUE"
    assert_equal "enabled", trigger.reload.status
    assert_nil trigger.last_error, "leaving `failed` sheds the error — that is why the task logs it first"
    assert_nil trigger.failed_at
    assert_equal 1, run.stats["rearmed"]
    assert_equal 1, run.stats["rearmed_schedule_wakes"]
    assert_equal 0, run.stats["skipped"]
    assert_equal 1, run.stats["candidates_examined"]
  end

  test "re-arms a bricked session-scoped ao_event wake" do
    session = a_session
    watched = a_session(status: :running)
    trigger = brick!(ao_event_wake_trigger(session: session, watched: watched))

    run, _outcome = run_task

    assert_equal "enabled", trigger.reload.status
    assert_equal 1, run.stats["rearmed"]
    assert_equal 1, run.stats["rearmed_ao_event_wakes"]
    assert_equal 0, run.stats["rearmed_schedule_wakes"]
  end

  # The whole point: the wake must actually DELIVER after the re-arm, and it must
  # do so despite being past-dated — which is the case the task decided not to
  # retime. A one-time schedule that has passed is immediately due, so the very
  # next ScheduleTriggerJob tick fires it.
  test "the re-armed past-dated wake fires on the next tick and resumes its session" do
    session = a_session
    trigger = wake_trigger(session: session, scheduled_at: 3.days.ago)
    brick!(trigger)

    run_task
    assert_equal "enabled", trigger.reload.status

    # Every other schedule trigger — the fixtures, the seeded ones — is out of the
    # way so the job's one tick is this wake and nothing else.
    Trigger.where.not(id: trigger.id).update_all(status: "disabled")

    assert_difference -> { Session.count }, 0, "a wake reuses its session; it must not spawn one" do
      ScheduleTriggerJob.perform_now
    end

    session.reload
    assert_not session.waiting?, "the wake should have resumed its session, not left it asleep"
    assert_equal "time to wake up", session.metadata["pending_follow_up_prompt"]
    assert_not_nil trigger.reload.wake_held_at,
      "a fired one-time wake is held for the turn it woke, and retired when that turn ends"
  end

  # --- the rows that MUST NOT be re-armed -----------------------------------

  test "leaves a trigger failed for any other reason alone" do
    session = a_session
    trigger = brick!(wake_trigger(session: session), StandardError.new("Slack API returned 500"))

    run, _outcome = run_task

    assert_equal "failed", trigger.reload.status
    assert_equal "StandardError: Slack API returned 500", trigger.last_error
    assert_equal 0, run.stats["rearmed"]
    assert_equal 0, run.stats["candidates_examined"], "it never even reaches the per-row checks"
  end

  test "leaves a wake whose target session is no longer waiting alone" do
    session = a_session
    trigger = brick!(wake_trigger(session: session))
    # After the trigger armed it, so the after_create sleep doesn't undo this.
    session.update_column(:status, Session.statuses[:needs_input])

    run, _outcome = run_task

    assert_equal "failed", trigger.reload.status
    assert_equal 0, run.stats["rearmed"]
    assert_equal({ "target_session_not_waiting" => 1 }, run.stats["skipped_by_reason"])
  end

  test "leaves a wake whose target session is gone alone" do
    session = a_session
    trigger = brick!(wake_trigger(session: session))
    Trigger.where(id: trigger.id).update_all(last_session_id: Session.maximum(:id).to_i + 1_000)

    run, _outcome = run_task

    assert_equal "failed", trigger.reload.status
    assert_equal({ "target_session_missing" => 1 }, run.stats["skipped_by_reason"])
  end

  test "leaves a spent one-shot alone — re-arming it would deliver a second session" do
    session = a_session
    trigger = brick!(wake_trigger(session: session))
    trigger.trigger_conditions.first.update!(last_triggered_at: 1.hour.ago)

    run, _outcome = run_task

    assert trigger.reload.spent_one_shot_wake?
    assert_equal "failed", trigger.status
    assert_equal({ "one_shot_already_consumed" => 1 }, run.stats["skipped_by_reason"])
  end

  test "leaves a wake whose target session a user paused alone" do
    session = a_session
    trigger = brick!(wake_trigger(session: session))
    session.update_column(:metadata, session.metadata.merge("paused_by" => "user"))

    run, _outcome = run_task

    assert_equal "failed", trigger.reload.status
    assert_equal({ "target_session_paused_by_user" => 1 }, run.stats["skipped_by_reason"])
  end

  test "leaves a recurring reuse trigger alone even when it carries the same error" do
    session = a_session
    trigger = Trigger.create!(
      name: "Nightly drumbeat",
      agent_root_name: "claude_code",
      prompt_template: "carry on",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [ {
        condition_type: "schedule",
        configuration: { "interval" => 1, "unit" => "days", "time" => "03:00", "timezone" => "UTC" }
      } ]
    )
    brick!(trigger)

    run, _outcome = run_task

    assert_equal "failed", trigger.reload.status
    assert_equal({ "not_a_one_time_reuse_wake" => 1 }, run.stats["skipped_by_reason"])
  end

  # The case StrandedSleepRescue creates: the session was bricked, that sweep
  # nudged it, the agent worked and armed a FRESH wake, and it is `waiting` on
  # purpose again. Firing the stale one would resume it early — and the delivery
  # would take #hold_wake_group! through the live wake on the way out.
  test "leaves a wake alone when its target is already resting on a wake that can still fire" do
    session = a_session
    stale = brick!(wake_trigger(session: session, scheduled_at: 5.days.ago))
    live = wake_trigger(session: session, scheduled_at: 2.days.from_now)

    assert session.reload.awaiting_scheduled_wake?

    run, _outcome = run_task

    assert_equal "failed", stale.reload.status
    assert_equal({ "target_session_has_a_live_wake" => 1 }, run.stats["skipped_by_reason"])
    assert_equal "enabled", live.reload.status, "the live wake is untouched"
  end

  test "leaves a spawner trigger alone even when it carries the same error" do
    trigger = Trigger.create!(
      name: "Nightly spawner",
      agent_root_name: "claude_code",
      prompt_template: "spawn something",
      reuse_session: false,
      trigger_conditions_attributes: [ {
        condition_type: "schedule",
        configuration: { "scheduled_at" => 2.hours.ago.utc.strftime("%Y-%m-%dT%H:%M:%S"), "timezone" => "UTC" }
      } ]
    )
    brick!(trigger)

    run, _outcome = run_task

    assert_equal "failed", trigger.reload.status
    assert_equal 0, run.stats["candidates_examined"], "a spawner is filtered out in SQL, not per-row"
  end

  test "leaves a trigger a human already disabled alone" do
    session = a_session
    trigger = brick!(wake_trigger(session: session))
    trigger.disable!

    run, _outcome = run_task

    assert_equal "disabled", trigger.reload.status
    assert_equal 0, run.stats["candidates_examined"]
  end

  # --- idempotency -----------------------------------------------------------

  test "a second run is a no-op" do
    session = a_session
    trigger = brick!(wake_trigger(session: session))

    first_run, _ = run_task
    assert_equal 1, first_run.stats["rearmed"]

    trigger.reload
    updated_at = trigger.updated_at

    # The realistic re-run: the slice died holding the lease, the ledger row went
    # `failed`, and it was re-armed from the health page. Without this the second
    # #claim! would refuse — the row is still `running` — and the test would prove
    # nothing about the ledger.
    first_run.finish_failure!(StandardError.new("worker died mid-slice"))
    assert first_run.rearm!

    second_run, outcome = run_task

    assert_nil outcome
    assert_equal 0, second_run.stats["rearmed"]
    assert_equal 0, second_run.stats["candidates_examined"]
    assert_equal [], second_run.stats["rearmed_details"]
    assert_equal "enabled", trigger.reload.status
    assert_equal updated_at.to_i, trigger.updated_at.to_i, "the second run must not touch the row"
  end

  # --- evidence --------------------------------------------------------------

  test "records the evidence the re-arm itself destroys" do
    session = a_session
    trigger = brick!(wake_trigger(session: session, scheduled_at: Time.utc(2026, 9, 1, 4, 30)))

    run, _outcome = run_task

    detail = run.stats["rearmed_details"].sole
    assert_equal trigger.id, detail["trigger_id"]
    assert_equal session.id, detail["session_id"]
    assert_equal "schedule", detail["shape"]
    assert_equal "2026-09-01T04:30:00", detail["scheduled_at"]
    assert_equal "claude_code", detail["agent_root_name"]
    assert_includes detail["last_error"], "AgentRootsConfig::AgentRootNotFoundError"
    assert detail["failed_at"].present?

    assert_nil trigger.reload.last_error, "the row no longer carries it — only the ledger and the log do"
  end

  test "counts a mixed population from both sides in one pass" do
    rearmable = brick!(wake_trigger(session: a_session))
    spent = brick!(wake_trigger(session: a_session))
    spent.trigger_conditions.first.update!(last_triggered_at: 1.hour.ago)
    awake_session = a_session
    not_waiting = brick!(wake_trigger(session: awake_session))
    awake_session.update_column(:status, Session.statuses[:running])

    run, _outcome = run_task

    assert_equal 1, run.stats["rearmed"]
    assert_equal 2, run.stats["skipped"]
    assert_equal 3, run.stats["candidates_examined"]
    assert_equal({ "one_shot_already_consumed" => 1, "target_session_not_waiting" => 1 },
                 run.stats["skipped_by_reason"])
    assert_equal "enabled", rearmable.reload.status
    assert_equal "failed", spent.reload.status
    assert_equal "failed", not_waiting.reload.status
  end

  # --- a row that will not save ---------------------------------------------

  test "one unenablable row does not cost the others their repair, and still parks the task" do
    healthy = brick!(wake_trigger(session: a_session))
    broken = brick!(wake_trigger(session: a_session))
    # A row that no longer passes its own validations. `enable!` goes through
    # `update!`, so it raises — and must not take the other wake down with it.
    Trigger.where(id: broken.id).update_all(name: "")

    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    error = assert_raises(RuntimeError) { @task_class.new(run: run, logger: Rails.logger).up }
    assert_includes error.message, broken.id.to_s

    run.reload
    assert_equal "enabled", healthy.reload.status, "the healthy row is repaired regardless"
    assert_equal "failed", broken.reload.status
    assert_equal 1, run.stats["rearmed"]
    assert_equal 1, run.stats["enable_failed"]
    assert_equal 2, run.stats["candidates_examined"]
  end

  # --- the measurement -------------------------------------------------------

  test "a population of zero is a legitimate outcome, not a failure" do
    Trigger.update_all(status: "enabled")

    run, outcome = run_task

    assert_nil outcome
    assert_equal 0, run.stats["rearmed"]
    assert_equal 0, run.stats["candidates_examined"]
    assert_equal({}, run.stats["skipped_by_reason"])
  end
end
