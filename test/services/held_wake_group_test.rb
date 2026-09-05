# frozen_string_literal: true

require "test_helper"

# A fired one-time wake used to void the rest of its group at fire time — before
# the woken turn had run, let alone re-armed anything. Re-arming is the woken
# turn's job and happens at the END of that turn, so between the fire and a
# successful re-arm the session held nothing at all. A turn interrupted anywhere
# in that window — a deploy restart, a killed process, a transient failure, all
# of which Zimmer's own nudge text calls routine — left the session asleep with
# no wake, and nothing distinguished it from a session sleeping correctly. In the
# filed instance a 04:52 deadline backstop was voided by a 04:18 fire and the
# session sat inert until an orphan sweep found it 4.5 hours later
# (https://github.com/tadasant/zimmer/issues/569).
#
# The contract these tests pin has two halves, and both are load-bearing:
#
#  1. The group SURVIVES a fire and survives an interrupted turn, so the wait is
#     still there to wake the session.
#  2. The group does NOT survive a turn that came to rest. A stale wake firing
#     into a later, unrelated wait is silent in exactly the same way the bug is,
#     so holding without retiring would trade one invisible failure for another.
class HeldWakeGroupTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    # Fixture triggers carrying broadcast ao_event conditions fire on any
    # autonomous session's transition, which would spawn sessions unrelated to
    # what is under test here.
    Trigger.where(status: "enabled").find_each do |trigger|
      trigger.update!(status: "disabled") if trigger.trigger_conditions.ao_event.exists?
    end
  end

  # The requester: an orchestrator that has run, come to rest, and is about to
  # arm the wake set every orchestrating session in the fleet is told to use.
  def requester_session
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "watch the child",
      agent_runtime: "claude_code",
      status: :needs_input,
      session_id: SecureRandom.uuid,
      is_autonomous: true,
      metadata: { "working_directory" => "/tmp/whatever", "agent_root_key" => "zimmer" }
    )
  end

  def child_session(status: :running)
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "do the work",
      agent_runtime: "claude_code",
      status: status,
      is_autonomous: true,
      metadata: {}
    )
  end

  # `wake_me_up_when_session_changes_state` builds ONE trigger carrying one
  # condition per event, which is what production rows look like.
  def watcher_for(requester, child)
    Trigger.create!(
      name: "Wake session ##{requester.id} on child ##{child.id}",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Child #{child.id} changed state — re-read the PR.",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: %w[session_needs_input session_archived session_failed].map do |event_name|
        { condition_type: "ao_event",
          configuration: { "event_name" => event_name, "watched_session_id" => child.id } }
      end
    )
  end

  # The `wake_me_up_later` deadline backstop beside it. Creating it is the atomic
  # sleep+schedule — the trigger's after_create callback puts the requester to
  # sleep — so this is also what leaves the session in `waiting`.
  def deadline_for(requester, at: 45.minutes.from_now)
    Sessions::ScheduleWakeUp.call(
      session: requester,
      wake_at: at.utc.strftime("%Y-%m-%dT%H:%M:%S"),
      prompt: "Deadline reached — re-read the PR."
    )
  end

  # Fire the watcher the way AoEventTriggerJob does when the child pauses.
  def child_reaches_needs_input!(child)
    child.update!(status: :needs_input)
    AoEventTriggerJob.perform_now("session_needs_input", child.id)
  end

  # === 1. The window ===

  test "a fired wake leaves the deadline backstop armed for the turn it just woke" do
    requester = requester_session
    child = child_session
    watcher = watcher_for(requester, child)
    deadline = deadline_for(requester)
    assert requester.reload.waiting?, "precondition: the requester is asleep on its wake set"

    child_reaches_needs_input!(child)

    assert requester.reload.running?, "precondition: the fire resumed the requester"
    assert Trigger.exists?(deadline.id),
      "the deadline backstop must survive the fire — it is the only thing that wakes an interrupted turn"
    assert_equal "enabled", deadline.reload.status
    assert_nil deadline.trigger_conditions.first.last_triggered_at,
      "a held backstop is unfired, so it can still fire"
    assert_not_nil deadline.wake_held_at, "and it is marked as owed a retirement by this turn"

    # The watcher holds itself: its needs_input condition is spent, but the
    # archived and failed conditions it also carries are the rest of the wait.
    watcher.reload
    assert_not_nil watcher.wake_held_at
    unfired = watcher.trigger_conditions.reject { |c| c.last_triggered_at.present? }
    assert_equal %w[session_archived session_failed],
      unfired.map { |c| c.configuration["event_name"] }.sort
  end

  # The regression test for the incident itself. The woken turn is interrupted
  # before it re-registers anything, and the wake it would have relied on still
  # fires.
  test "the deadline backstop still wakes a session whose woken turn was interrupted" do
    requester = requester_session
    child = child_session
    watcher_for(requester, child)
    deadline = deadline_for(requester)

    child_reaches_needs_input!(child)
    assert requester.reload.running?

    # The interruption: a deploy restart, a killed process. Every recovery path
    # writes `paused_by = "recovery"` immediately before pausing, which is how a
    # turn Zimmer cut short is told apart from a turn that finished.
    requester.update!(metadata: requester.metadata.merge("paused_by" => "recovery"))
    requester.pause!

    assert Trigger.exists?(deadline.id),
      "an interrupted turn must not take the wake set with it"

    travel_to 1.hour.from_now do
      ScheduleTriggerJob.perform_now
    end

    assert requester.reload.running?,
      "expected the backstop to wake the interrupted session, got #{requester.status}"
  end

  # The same interruption, seen through the predicate every sweep and every UI
  # surface asks. Before the fix this session read as `waiting` with nothing that
  # could fire — indistinguishable from one sleeping correctly.
  test "an interrupted woken turn still reads as holding an armed wake" do
    requester = requester_session
    child = child_session
    watcher_for(requester, child)
    deadline_for(requester)

    child_reaches_needs_input!(child)
    requester.reload.update!(metadata: requester.metadata.merge("paused_by" => "recovery", "pending_sleep" => true))
    requester.pause!

    assert requester.reload.waiting?, "precondition: the recovery pause left it asleep"
    assert requester.awaiting_scheduled_wake?,
      "a session asleep after an interrupted woken turn must still hold a fireable wake"
  end

  # === 2. The anti-regression half ===

  test "a turn that comes to rest retires the wake group it was woken for" do
    requester = requester_session
    child = child_session
    watcher = watcher_for(requester, child)
    deadline = deadline_for(requester)

    child_reaches_needs_input!(child)
    assert requester.reload.running?

    # The turn ends normally — no recovery marker.
    requester.pause!

    assert_not Trigger.exists?(deadline.id),
      "a backstop belonging to a finished wait must not survive to fire into the next one"
    assert_not Trigger.exists?(watcher.id),
      "nor may the watcher, whose remaining conditions are equally moot"
  end

  test "a retired wake group cannot fire after the turn it belonged to" do
    requester = requester_session
    child = child_session
    watcher_for(requester, child)
    deadline_for(requester)

    child_reaches_needs_input!(child)
    requester.reload.pause!
    assert requester.reload.needs_input?

    travel_to 1.hour.from_now do
      ScheduleTriggerJob.perform_now
    end

    assert requester.reload.needs_input?,
      "a spent deadline must not resume a session that already came to rest"

    # And the watcher's remaining events are just as spent.
    child.update!(status: :running)
    assert_no_difference("EnqueuedMessage.count") do
      child.archive!
      perform_enqueued_jobs(only: AoEventTriggerJob)
    end
  end

  # The half that makes retirement safe to run at every pause: a wake the woken
  # turn armed FOR ITSELF is not part of the group that woke it, carries no hold
  # mark, and must survive the very pause that retires the old one.
  test "a wake armed during the woken turn survives the pause that retires the old group" do
    requester = requester_session
    child = child_session
    watcher_for(requester, child)
    old_deadline = deadline_for(requester)

    child_reaches_needs_input!(child)
    assert requester.reload.running?

    # What the woken turn does before it ends: re-register.
    new_child = child_session
    new_watcher = watcher_for(requester, new_child)
    new_deadline = deadline_for(requester, at: 90.minutes.from_now)

    requester.reload.pause!

    assert_not Trigger.exists?(old_deadline.id), "the old backstop is retired"
    assert Trigger.exists?(new_watcher.id), "the turn's own watcher must survive"
    assert Trigger.exists?(new_deadline.id), "and so must its own backstop"
    assert_nil new_deadline.reload.wake_held_at
    assert requester.reload.waiting?, "and the session sleeps on them"
  end

  # A deliberate resume is not a wake fire. A human following up, or a restart,
  # consumes the pending wakes exactly as before — there is no wait left to
  # protect once somebody has decided the session should be awake.
  test "a deliberate resume still consumes the pending wake group outright" do
    requester = requester_session
    child = child_session
    watcher = watcher_for(requester, child)
    deadline = deadline_for(requester)

    requester.reload.resume!

    assert_not_nil deadline.trigger_conditions.first.reload.last_triggered_at,
      "a deliberate resume consumes the backstop"
    watcher.reload.trigger_conditions.each do |condition|
      assert_not_nil condition.last_triggered_at, "and every watcher condition with it"
    end
    assert_nil deadline.reload.wake_held_at, "nothing is held, so nothing is owed a retirement"
  end

  # An archive is a rest like any other. Without this the held group would sit at
  # /triggers as enabled rows against a session nobody can follow up into, until
  # CleanupStaleTriggersJob's hourly sweep reached it.
  test "archiving the requester retires the group held across its turn" do
    requester = requester_session
    child = child_session
    watcher = watcher_for(requester, child)
    deadline = deadline_for(requester)

    child_reaches_needs_input!(child)
    requester.reload.archive!

    assert_not Trigger.exists?(deadline.id)
    assert_not Trigger.exists?(watcher.id)
  end

  # `paused_by = "recovery"` is not the only way a turn reaches `pause` without
  # having run. Sessions::ParkUndeliveredTurn says so in its own class comment —
  # it deliberately writes no `paused_by` — and it is reached by a turn that
  # raised during setup, before the agent process existed. A woken turn that never
  # started has not had its chance to re-arm.
  test "a turn parked before the agent ran keeps the wake group" do
    requester = requester_session
    child = child_session
    watcher_for(requester, child)
    deadline = deadline_for(requester)

    child_reaches_needs_input!(child)
    assert requester.reload.running?

    requester.update!(metadata: requester.metadata.merge(
      "failure_reason" => Sessions::ParkUndeliveredTurn::FAILURE_REASON
    ))
    requester.pause!

    assert Trigger.exists?(deadline.id),
      "a turn that stopped before the agent started must not take the wake set with it"

    travel_to 1.hour.from_now do
      ScheduleTriggerJob.perform_now
    end

    assert requester.reload.running?, "the backstop must still wake it"
  end

  # The same shape through the auth-outage park: the account pool was empty, the
  # CLI stopped without delivering the prompt, and AuthOutageParkService marks the
  # session `pending_sleep` so the pause carries it to `waiting`. Retiring there
  # would leave it asleep with nothing — and its own marker excludes it from
  # StrandedSleepRescue, so no sweep would find it either.
  test "a turn stood down by an auth outage keeps the wake group" do
    requester = requester_session
    child = child_session
    watcher_for(requester, child)
    deadline = deadline_for(requester)

    child_reaches_needs_input!(child)
    requester.reload.update!(metadata: requester.metadata.merge(
      "auth_outage_reason" => "pool_empty", "pending_sleep" => true
    ))
    requester.pause!

    assert requester.reload.waiting?, "precondition: the park slept it"
    assert Trigger.exists?(deadline.id), "an undelivered turn must not take the wake set with it"
    assert requester.awaiting_scheduled_wake?, "and it still reads as holding a fireable wake"
  end

  # Holding hands the whole trigger ROW to the retirement, which destroys it. A
  # trigger that mixes an unfired one-shot with a recurring condition does other
  # work, so it must be consumed the old way rather than held — otherwise the
  # requester's next pause deletes a cron the user set up.
  test "a trigger that does other work is consumed, not held" do
    requester = requester_session
    child = child_session
    watcher_for(requester, child)

    mixed = Trigger.create!(
      name: "Wake ##{requester.id}, and also every morning",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event",
          configuration: { "event_name" => "session_archived", "watched_session_id" => child.id } },
        { condition_type: "schedule",
          configuration: { "unit" => "days", "interval" => 1, "time" => "09:00", "timezone" => "UTC" } }
      ]
    )
    assert_not mixed.one_time_reuse_trigger?, "precondition: this trigger is not purely a wake"

    child_reaches_needs_input!(child)

    assert_nil mixed.reload.wake_held_at, "a trigger that does other work is not the turn's to retire"
    assert_not_nil mixed.trigger_conditions.find_by(condition_type: "ao_event").last_triggered_at,
      "but its one-shot is consumed, exactly as a resume always consumed it"

    requester.reload.pause!

    assert Trigger.exists?(mixed.id), "and the recurring half survives the pause"
    assert_nil mixed.reload.trigger_conditions.find_by(condition_type: "schedule").last_triggered_at
  end

  # A wake parked `failed` keeps its hold mark, because retirement exempts failed
  # rows. Re-arming it is a fresh promise owed to nobody, so the mark has to go —
  # otherwise the requester's next pause destroys the wake the user just re-armed.
  test "re-arming a held wake clears the hold, so the next pause does not destroy it" do
    requester = requester_session
    child = child_session
    watcher_for(requester, child)
    deadline = deadline_for(requester)

    child_reaches_needs_input!(child)
    assert_not_nil deadline.reload.wake_held_at

    deadline.mark_failed(StandardError.new("agent root not found"))
    assert_not_nil deadline.reload.wake_held_at, "a parked wake keeps the record of its hold"

    deadline.toggle!
    assert_equal "enabled", deadline.reload.status
    assert_nil deadline.wake_held_at, "a re-arm is owed to nobody"

    requester.reload.pause!

    assert Trigger.exists?(deadline.id), "so the re-armed wake survives the pause"
  end

  # A failed sibling is the record of a wake that tried and could not. It is the
  # user's to clear, so neither the fire nor the retirement may sweep it up.
  test "a failed sibling is neither held nor retired" do
    requester = requester_session
    child = child_session
    watcher_for(requester, child)
    deadline = deadline_for(requester)
    parked = deadline_for(requester, at: 20.minutes.from_now)
    parked.mark_failed(StandardError.new("agent root not found"))

    child_reaches_needs_input!(child)
    requester.reload.pause!

    assert_not Trigger.exists?(deadline.id), "the healthy backstop is retired with the turn"
    assert Trigger.exists?(parked.id), "the parked one carries evidence and survives"
    assert_equal "failed", parked.reload.status
    assert_nil parked.wake_held_at
  end
end
