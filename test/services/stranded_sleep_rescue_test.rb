# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The sweep for a session asleep on a wake-up that can never fire.
#
# Production session 6412 — a router orchestrating several children — slept for
# 38.7 hours after its deadline backstop vanished and its state-change watcher
# was left holding one condition that watched an already-archived session. It was
# `waiting`, with a trigger row that read `enabled`, and it was indistinguishable
# from a session sleeping correctly to the UI, to `get_session`, and to every
# sweep Zimmer runs. https://github.com/tadasant/zimmer/issues/855
#
# Two halves, and both are load-bearing. A stranded sleeper must come back — and
# a session sleeping on a wake that CAN still fire must be left exactly alone.
class StrandedSleepRescueTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    GoodJob::Job.delete_all
    # Fixture sessions sitting in `waiting` are legitimate candidates for this
    # sweep, so move them out of its population rather than asserting around them.
    Session.where(status: :waiting).update_all(status: Session.statuses[:needs_input])
    AlertService.stubs(:raise_alert)
  end

  # A session that ran, went to sleep, and has been quiet since.
  def sleeping_session(age: StrandedSleepRescue::GRACE + 5.minutes, **attributes)
    session = Session.create!(
      git_root: "https://github.com/tadasant/zimmer.git",
      prompt: "orchestrate the children",
      status: :waiting,
      session_id: SecureRandom.uuid,
      **attributes
    )
    session.update_columns(created_at: age.ago, updated_at: age.ago)
    session.reload
  end

  def other_session(status: :running)
    Session.create!(
      git_root: "https://github.com/tadasant/zimmer.git",
      prompt: "child work",
      status: status,
      session_id: SecureRandom.uuid
    )
  end

  def back_date(session, age: StrandedSleepRescue::GRACE + 5.minutes)
    session.update_columns(updated_at: age.ago)
    session.reload
  end

  # Arms a wake against `session` without going through the after_create hooks
  # that would sleep or immediately fire it — the session is already asleep here.
  def arm_wake!(session, conditions)
    trigger = Trigger.new(
      name: "Wake session ##{session.id}",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "you were watching something",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: conditions
    )
    trigger.save!(validate: true)
    trigger
  end

  def ao_event_condition(watched, event_name: "session_archived")
    { condition_type: "ao_event",
      configuration: { "event_name" => event_name, "watched_session_id" => watched.id } }
  end

  def schedule_condition(at)
    { condition_type: "schedule",
      configuration: { "scheduled_at" => at.utc.strftime("%Y-%m-%dT%H:%M:%S"), "timezone" => "UTC" } }
  end

  def queue_a_turn_for(session)
    GoodJob::Job.create!(
      job_class: "AgentSessionJob", queue_name: "agents", scheduled_at: 1.minute.from_now,
      serialized_params: { "job_class" => "AgentSessionJob", "arguments" => [ session.id ] }
    )
  end

  # --- the core defect ---------------------------------------------------------

  test "a session asleep with no trigger at all is resumed" do
    session = sleeping_session

    result = nil
    assert_enqueued_with(job: AgentSessionJob, args: ->(args) { args.first == session.id }) do
      result = StrandedSleepRescue.sweep!
    end

    assert_equal 1, result.rescued
    assert_equal 1, result.found
    assert_equal "running", session.reload.status
    assert_equal 1, session.metadata[StrandedSleepRescue::RESCUE_COUNT]
  end

  # The case that defeated observation in #855: the row exists, reads `enabled`,
  # and has never fired — but its watched session is archived and will never
  # transition again. A sweep keyed on the ABSENCE of trigger rows walks past it.
  #
  # `other_session(status: :archived)` writes the row straight to `archived`
  # without running the transition, so `archived_at` is nil — which is also the
  # shape of every session archived before that column existed. Unfireable either
  # way; the freshly-dated archival is a separate case with its own tests below.
  test "a session asleep on an ao_event wake whose watched session is archived is resumed" do
    session = sleeping_session
    watched = other_session(status: :archived)
    trigger = arm_wake!(session, [ ao_event_condition(watched) ])
    back_date(session)

    assert_equal "enabled", trigger.reload.status
    assert_nil trigger.trigger_conditions.sole.last_triggered_at

    result = StrandedSleepRescue.sweep!

    assert_equal 1, result.rescued, "an unfireable-but-enabled wake must not count as sleeping on purpose"
    assert_equal "running", session.reload.status
  end

  test "a session asleep on an ao_event wake whose watched session no longer exists is resumed" do
    session = sleeping_session
    watched = other_session
    arm_wake!(session, [ ao_event_condition(watched) ])
    watched.destroy!
    back_date(session)

    assert_equal 1, StrandedSleepRescue.sweep!.rescued
  end

  # A wake whose wall time passed without it firing is a wake nobody got. The
  # session is stuck, not resting — the same reading TriggerCondition#schedule_due?
  # takes when it reports the schedule still due.
  test "a session asleep on a one-time schedule whose moment has passed is resumed" do
    session = sleeping_session
    arm_wake!(session, [ schedule_condition(2.hours.ago) ])
    back_date(session)

    assert_equal 1, StrandedSleepRescue.sweep!.rescued
  end

  # --- the half that must not fire ---------------------------------------------

  test "a session asleep on an ao_event wake whose watched session is live is left alone" do
    session = sleeping_session
    watched = other_session(status: :running)
    arm_wake!(session, [ ao_event_condition(watched) ])
    back_date(session)

    result = StrandedSleepRescue.sweep!

    assert_equal 0, result.rescued
    assert_equal 0, result.found
    assert_equal "waiting", session.reload.status
  end

  test "a session asleep on an ao_event wake whose watched session merely failed is left alone" do
    session = sleeping_session
    watched = other_session(status: :failed)
    arm_wake!(session, [ ao_event_condition(watched) ])
    back_date(session)

    assert_equal 0, StrandedSleepRescue.sweep!.rescued,
      "a failed session can still be restarted or archived, so a watcher on it is live"
  end

  test "a session asleep on a one-time schedule still ahead of it is left alone" do
    session = sleeping_session
    arm_wake!(session, [ schedule_condition(3.hours.from_now) ])
    back_date(session)

    assert_equal 0, StrandedSleepRescue.sweep!.rescued
    assert_equal "waiting", session.reload.status
  end

  # === a wake in flight is not a wake that was lost ============================
  #
  # The false positive, reproduced to the second. On 2026-09-05 session 13229 —
  # a router asleep on a verification wake it had scheduled for itself — was
  # rescued eight seconds after that wake came due and fired for real ten seconds
  # after that. Zimmer alerted `#alerts` that the session "was in `waiting` with
  # no trigger that could ever fire" about a trigger that fired while the alert
  # was being posted, resumed the session into the turn the wake was about to
  # land in, and the prompt the wake carried never reached the agent.
  #
  # There is no scheduler latency low enough to avoid this. ScheduleTriggerJob is
  # a one-minute cron and this sweep is a five-minute one, so a wake set for any
  # multiple of five minutes — which is what an agent scheduling "11:20 UTC"
  # writes — races it every single time.
  test "a wake that has come due but has not been fired yet is left alone, and then delivers" do
    session = sleeping_session
    due_at = 1.minute.from_now.change(usec: 0)
    trigger = arm_wake!(session, [ schedule_condition(due_at) ])
    back_date(session)

    # T+15s: the sweep runs while ScheduleTriggerJob's tick is still in flight.
    travel_to(due_at + 15.seconds) do
      result = StrandedSleepRescue.sweep!

      assert_equal 0, result.found,
        "a due-but-unfired wake is being delivered, not lost — the sweep must not touch it"
      assert_equal "waiting", session.reload.status
      assert_nil session.metadata[StrandedSleepRescue::RESCUE_COUNT]
      assert_nil trigger.trigger_conditions.sole.reload.last_triggered_at
    end

    # T+18s: the scheduler reaches the row and the wake lands, into a session
    # that is still asleep and can take it.
    travel_to(due_at + 18.seconds) { ScheduleTriggerJob.perform_now }

    session.reload
    assert_equal "running", session.status
    assert_equal "you were watching something", session.metadata["pending_follow_up_prompt"],
      "the wake's own prompt must be what resumes the session, not a recovery nudge"
  end

  # The window is bounded, so the hole #855 closed stays closed: a wake the
  # scheduler has had every chance to reach and still has not fired is a wake
  # that is not coming.
  test "a wake still unfired long after the scheduler should have reached it is stranded" do
    session = sleeping_session
    due_at = 1.minute.from_now.change(usec: 0)
    arm_wake!(session, [ schedule_condition(due_at) ])
    back_date(session)

    travel_to(due_at + SessionStateMachine::SCHEDULE_FIRE_SETTLE + 1.minute) do
      assert_equal 1, StrandedSleepRescue.sweep!.rescued
      assert_equal "running", session.reload.status
    end
  end

  # The same race through the other door. #cleanup_watched_session_ao_event_triggers
  # deliberately spares a `session_archived` watcher when the session it watches
  # archives — because AoEventTriggerJob is enqueued after that transaction
  # commits and has not run yet. Between the two, the surviving row is a wake
  # being delivered, and reading "watched session is archived" as "can never fire"
  # would barge the sleeper in exactly the window the sparing exists to protect.
  test "a session asleep on a watcher whose watched session archived a moment ago is left alone" do
    session = sleeping_session
    watched = other_session(status: :needs_input)
    arm_wake!(session, [ ao_event_condition(watched) ])
    watched.archive!
    back_date(session)

    assert_equal "archived", watched.reload.status
    assert_not_nil watched.archived_at

    assert_equal 0, StrandedSleepRescue.sweep!.rescued,
      "the fire for this archival is still queued; the wake has not been missed"
    assert_equal "waiting", session.reload.status
  end

  # ...and once the job has had every chance to run, the watcher really has
  # missed its only chance, which is #855 itself.
  test "a session asleep on a watcher whose watched session archived long ago is resumed" do
    session = sleeping_session
    watched = other_session(status: :needs_input)
    arm_wake!(session, [ ao_event_condition(watched) ])
    watched.archive!
    watched.update_column(:archived_at, (SessionStateMachine::SCHEDULE_FIRE_SETTLE + 1.minute).ago)
    back_date(session)

    assert_equal 1, StrandedSleepRescue.sweep!.rescued
  end

  # The window is for the watcher that fires ON the archival and nothing else.
  # Any other watcher on an archived session has missed its only chance — that is
  # #855 — so the narrowing to `session_archived` is what stops the window
  # re-opening #855 for ten minutes after every archival in the fleet. Delete that
  # one line and the rest of the suite stays green, which is why this exists.
  #
  # The watcher is armed AFTER the archive on purpose:
  # #cleanup_watched_session_ao_event_triggers destroys a non-archival watcher as
  # the watched session archives, so the only way this shape exists in production
  # is the way #855 made it — a row that outlived the cleanup, or was armed
  # against an already-archived session. Arming it before the archive would leave
  # the session with no trigger at all and the test would pass without ever
  # reaching the predicate.
  test "a non-archival watcher on a freshly-archived session is stranded immediately" do
    session = sleeping_session
    watched = other_session(status: :needs_input)
    watched.archive!
    arm_wake!(session, [ ao_event_condition(watched, event_name: "session_needs_input") ])
    back_date(session)

    assert_not_nil watched.reload.archived_at, "the archive must be freshly dated for this to mean anything"
    assert_equal 1, StrandedSleepRescue.sweep!.rescued,
      "only a session_archived watcher is in flight after an archival; this one missed its chance"
  end

  # One condition of a multi-event watcher still being fireable is enough: the
  # trigger ORs its conditions.
  test "a multi-event watcher with one live condition is left alone" do
    session = sleeping_session
    archived = other_session(status: :archived)
    live = other_session(status: :running)
    arm_wake!(session, [ ao_event_condition(archived), ao_event_condition(live, event_name: "session_needs_input") ])
    back_date(session)

    assert_equal 0, StrandedSleepRescue.sweep!.rescued
  end

  test "a session that only just went to sleep is inside the grace window" do
    sleeping_session(age: 1.minute)

    assert_equal 0, StrandedSleepRescue.sweep!.rescued
  end

  test "a session with a pending enqueued message is left alone" do
    session = sleeping_session
    session.enqueued_messages.create!(content: "here is the answer", position: 1, status: "pending")
    back_date(session)

    assert_equal 0, StrandedSleepRescue.sweep!.rescued,
      "something is already on its way to this session"
  end

  test "a session with an unfinished AgentSessionJob is left alone" do
    session = sleeping_session
    queue_a_turn_for(session)

    assert_equal 0, StrandedSleepRescue.sweep!.rescued
  end

  test "a session that has never run is left to the stalled-start sweep" do
    session = sleeping_session
    session.update_columns(session_id: nil)

    assert_equal 0, StrandedSleepRescue.sweep!.rescued,
      "a session with no runtime id has no conversation to resume into"
  end

  StrandedSleepRescue::DORMANT_MARKERS.each do |marker|
    test "a session carrying #{marker} is left to the sweep that owns it" do
      session = sleeping_session
      session.merge_metadata!(marker => "held")
      back_date(session)

      assert_equal 0, StrandedSleepRescue.sweep!.rescued
    end
  end

  # The one path into `waiting` that arms nothing and marked nothing before this
  # PR: POST /api/v1/sessions/:id/sleep. Without the marker the sweep cannot tell
  # a deliberate sleep from a destroyed wake set, and would resume it claiming
  # its wake had been lost.
  test "a session slept deliberately through the API is left alone" do
    session = sleeping_session
    session.merge_metadata!(Session::DELIBERATE_SLEEP_KEY => Time.current.iso8601)
    back_date(session)

    assert_equal 0, StrandedSleepRescue.sweep!.rescued
    assert_equal "waiting", session.reload.status
  end

  # #awaiting_scheduled_wake? ignores recurring conditions by design — they are
  # not per-session wake-ups — but a recurring trigger pointed at this session as
  # its reuse target really will follow up into it. That is a session being
  # driven, not a stranded one.
  test "a session with a recurring trigger aimed at it is left alone" do
    session = sleeping_session
    Trigger.create!(
      name: "Heartbeat for ##{session.id}",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "tick",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "interval" => 1, "unit" => "hours" } }
      ]
    )
    back_date(session)

    assert_not session.reload.awaiting_scheduled_wake?,
      "guard: a recurring schedule is deliberately not an armed one-time wake"
    assert_equal 0, StrandedSleepRescue.sweep!.rescued,
      "but something is still going to wake it, so the sweep must stand down"
  end

  test "a disabled recurring trigger does not protect a stranded session" do
    session = sleeping_session
    trigger = Trigger.create!(
      name: "Heartbeat for ##{session.id}",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "tick",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "interval" => 1, "unit" => "hours" } }
      ]
    )
    trigger.update!(status: "disabled")
    back_date(session)

    assert_equal 1, StrandedSleepRescue.sweep!.rescued
  end

  test "the rescue budget is spent in the same write that resumes the session" do
    session = sleeping_session

    assert_equal 1, StrandedSleepRescue.sweep!.rescued
    assert_equal 1, session.reload.metadata[StrandedSleepRescue::RESCUE_COUNT],
      "the counter must survive the STALE_RETRY_METADATA_KEYS clear inside the claim"
    assert_equal "running", session.status
  end

  # The budget check must not fire ahead of the re-check: a session that armed a
  # wake between the batch read and the reload is not stranded, and abandoning it
  # would stamp it, write an error to its timeline and alert about a session that
  # had just fixed itself.
  test "a session at the rescue budget that has re-armed a wake is left alone, not abandoned" do
    session = sleeping_session
    session.merge_metadata!(StrandedSleepRescue::RESCUE_COUNT => StrandedSleepRescue::MAX_RESCUES)
    watched = other_session(status: :running)
    arm_wake!(session, [ ao_event_condition(watched) ])
    back_date(session)

    result = StrandedSleepRescue.sweep!

    assert_equal 0, result.abandoned
    assert_nil session.reload.metadata[StrandedSleepRescue::ABANDONED]
  end

  test "an alert failure does not make a completed rescue report as refused" do
    session = sleeping_session
    AlertService.unstub(:raise_alert)
    AlertService.stubs(:raise_alert).raises(StandardError, "slack is down")

    result = StrandedSleepRescue.sweep!

    assert_equal 1, result.rescued, "the turn was enqueued; a Slack failure must not misreport that"
    assert_equal "running", session.reload.status
  end

  test "a session in a frozen category is left alone" do
    frozen = Category.create!(name: "Parked #{SecureRandom.hex(4)}", is_frozen: true)
    session = sleeping_session(category: frozen)

    assert_equal 0, StrandedSleepRescue.sweep!.rescued
  end

  # --- budget and bounds -------------------------------------------------------

  test "a rescue stamps updated_at, so the session is out of the population until the grace elapses again" do
    session = sleeping_session

    assert_equal 1, StrandedSleepRescue.sweep!.rescued

    session.reload.update_columns(status: Session.statuses[:waiting])
    assert_equal 0, StrandedSleepRescue.sweep!.rescued,
      "merge_metadata! stamped updated_at, which is the cooldown"
  end

  test "Zimmer stops after MAX_RESCUES and marks the session abandoned" do
    session = sleeping_session
    session.merge_metadata!(StrandedSleepRescue::RESCUE_COUNT => StrandedSleepRescue::MAX_RESCUES)
    back_date(session)

    result = nil
    assert_no_enqueued_jobs(only: AgentSessionJob) do
      result = StrandedSleepRescue.sweep!
    end

    assert_equal 1, result.abandoned
    assert_equal 0, result.rescued
    assert session.reload.metadata[StrandedSleepRescue::ABANDONED].present?
  end

  test "an abandoned session is not swept again" do
    session = sleeping_session
    session.merge_metadata!(StrandedSleepRescue::ABANDONED => Time.current.iso8601)
    back_date(session)

    assert_equal 0, StrandedSleepRescue.sweep!.found
  end

  # The pass stops paging as soon as it has enough to act on, so `found` reports
  # what it acted on rather than the size of the population — see the Sweep
  # struct's own note on why one number cannot honestly be both.
  test "one pass acts on at most MAX_ACTIONS_PER_SWEEP sessions" do
    (StrandedSleepRescue::MAX_ACTIONS_PER_SWEEP + 2).times { sleeping_session }

    result = StrandedSleepRescue.sweep!

    assert_equal StrandedSleepRescue::MAX_ACTIONS_PER_SWEEP, result.rescued
    assert_equal StrandedSleepRescue::MAX_ACTIONS_PER_SWEEP, result.found
    assert_operator result.examined, :>=, StrandedSleepRescue::MAX_ACTIONS_PER_SWEEP
  end

  test "the leftovers from a capped pass are picked up by the next one" do
    (StrandedSleepRescue::MAX_ACTIONS_PER_SWEEP + 2).times { sleeping_session }

    assert_equal StrandedSleepRescue::MAX_ACTIONS_PER_SWEEP, StrandedSleepRescue.sweep!.rescued
    assert_equal 2, StrandedSleepRescue.sweep!.rescued,
      "the sessions the cap left behind must not be forgotten"
  end

  # The starvation the paging exists to prevent. A legitimately sleeping session
  # does not advance `updated_at` while it sleeps, so a wake set days out sits at
  # the head of an oldest-first ordering for days. Filtering fireability after a
  # single LIMIT would let a page-full of them hide every stranded session behind
  # them — permanently, and while logging that it found none.
  test "a page full of legitimate sleepers does not hide a stranded session behind them" do
    watched = other_session(status: :running)
    (StrandedSleepRescue::PAGE_SIZE + 5).times do
      sleeper = sleeping_session(age: 30.days)
      arm_wake!(sleeper, [ ao_event_condition(watched, event_name: "session_needs_input") ])
      back_date(sleeper, age: 30.days)
    end

    # Newer than every one of them, so it sorts last and is only reached by paging.
    stranded = sleeping_session

    result = StrandedSleepRescue.sweep!

    assert_equal 1, result.rescued
    assert_equal "running", stranded.reload.status
  end

  # page_after's cursor is a (updated_at, id) PAIR because updated_at alone is not
  # unique: a page boundary landing inside a run of equal timestamps would either
  # skip the rest of the run or loop over it forever. The starvation test above
  # gives every session a distinct microsecond timestamp, so it never exercises
  # this — the run of identical ones does.
  test "a run of identical updated_at values longer than a page does not skip or loop" do
    watched = other_session(status: :running)
    sleepers = (StrandedSleepRescue::PAGE_SIZE + 5).times.map do
      sleeper = sleeping_session(age: 30.days)
      arm_wake!(sleeper, [ ao_event_condition(watched, event_name: "session_needs_input") ])
      sleeper
    end
    stranded = sleeping_session(age: 30.days)

    # Every candidate carries the SAME updated_at, so the ordering is decided
    # entirely by the id half of the cursor.
    same_moment = 30.days.ago
    Session.where(id: sleepers.map(&:id) + [ stranded.id ]).update_all(updated_at: same_moment)

    result = StrandedSleepRescue.sweep!

    assert_equal 1, result.rescued
    assert_equal "running", stranded.reload.status
  end

  # A rescue that raises rolls its budget increment back with the transaction, so
  # without a cooldown the session neither advances toward MAX_RESCUES nor leaves
  # the population — it holds one of the pass's five action slots forever.
  test "a session the sweep could not rescue is cooled down rather than retried every pass" do
    session = sleeping_session
    Session.any_instance.stubs(:claim_system_recovery_turn!).raises(RuntimeError, "boom")

    result = StrandedSleepRescue.sweep!

    assert_equal 0, result.rescued
    assert_equal 1, result.found
    assert_operator session.reload.updated_at, :>, StrandedSleepRescue::GRACE.ago,
      "the failed session must fall out of the candidate set for a GRACE"
  end

  test "an archived session is never resumed" do
    session = sleeping_session
    Session.where(id: session.id).update_all(status: Session.statuses[:archived])

    assert_equal 0, StrandedSleepRescue.sweep!.found
  end

  test "the sweep never raises" do
    StrandedSleepRescue.stubs(:candidates).raises(ActiveRecord::StatementInvalid, "boom")

    result = nil
    assert_nothing_raised { result = StrandedSleepRescue.sweep! }
    assert_equal 0, result.rescued
  end

  test "an unreadable trigger table leaves the session asleep rather than waking it" do
    session = sleeping_session
    Session.any_instance.stubs(:pending_one_time_wake_conditions)
      .raises(ActiveRecord::StatementInvalid, "trigger table gone")

    assert_equal 0, StrandedSleepRescue.sweep!.rescued,
      "awaiting_scheduled_wake? fails safe to `asleep on purpose`, which costs a pass"
  end
end
