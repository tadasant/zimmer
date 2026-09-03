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
    assert_equal 1, result.stranded
    assert_equal "running", session.reload.status
    assert_equal 1, session.metadata[StrandedSleepRescue::RESCUE_COUNT]
  end

  # The case that defeated observation in #855: the row exists, reads `enabled`,
  # and has never fired — but its watched session is archived and will never
  # transition again. A sweep keyed on the ABSENCE of trigger rows walks past it.
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
    assert_equal 0, result.stranded
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

    assert_equal 0, StrandedSleepRescue.sweep!.stranded
  end

  test "one pass acts on at most MAX_ACTIONS_PER_SWEEP sessions but counts them all" do
    (StrandedSleepRescue::MAX_ACTIONS_PER_SWEEP + 2).times { sleeping_session }

    result = StrandedSleepRescue.sweep!

    assert_equal StrandedSleepRescue::MAX_ACTIONS_PER_SWEEP, result.rescued
    assert_equal StrandedSleepRescue::MAX_ACTIONS_PER_SWEEP + 2, result.stranded
  end

  test "an archived session is never resumed" do
    session = sleeping_session
    Session.where(id: session.id).update_all(status: Session.statuses[:archived])

    assert_equal 0, StrandedSleepRescue.sweep!.stranded
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
