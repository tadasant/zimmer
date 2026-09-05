# frozen_string_literal: true

require "test_helper"

# What `sessions.status = running` is worth as a measure of how busy the fleet is.
#
# The property under test is the one #957 was about: a row lands in `running` the
# moment a turn is HANDED to a session, so the column holds turns being executed
# and turns queued behind the `agents` worker pool at the same time — and, when a
# turn ends with something else already in flight, rows that are asleep on their
# own wake and will not be started before it.
class RunningTurnsTest < ActiveSupport::TestCase
  setup do
    # The fixtures ship sessions in every status, and every case here states its
    # own fleet.
    Session.delete_all
  end

  def session(status: :running, running_job_id: nil, runtime: ClaudeAuthProvider::RUNTIME)
    Session.create!(
      git_root: "https://github.com/tadasant/zimmer.git",
      prompt: "work",
      status: status,
      agent_runtime: runtime,
      session_id: SecureRandom.uuid,
      running_job_id: running_job_id
    )
  end

  # A GoodJob row in the state a worker leaves it in while it is performing:
  # picked up (`performed_at`) and not yet done (`finished_at`).
  def job_on_a_worker!(active_job_id, performed_at: 1.minute.ago)
    GoodJob::Job.create!(
      active_job_id: active_job_id, queue_name: "agents", job_class: "AgentSessionJob",
      serialized_params: {}, scheduled_at: 2.minutes.ago, performed_at: performed_at
    )
  end

  # The same row before anything picks it up — the queue behind the pool.
  def job_queued!(active_job_id)
    GoodJob::Job.create!(
      active_job_id: active_job_id, queue_name: "agents", job_class: "AgentSessionJob",
      serialized_params: {}, scheduled_at: 2.minutes.ago
    )
  end

  # Arms a one-time wake against `session` for a time that has not come, without
  # the after_create hooks that would sleep or fire it.
  def arm_wake!(session, at: 20.minutes.from_now)
    Trigger.new(
      name: "Wake session ##{session.id}",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "wake up",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule",
          configuration: { "scheduled_at" => at.utc.strftime("%Y-%m-%dT%H:%M:%S"), "timezone" => "UTC" } }
      ]
    ).save!(validate: true)
  end

  test "an empty fleet reads as nothing in flight" do
    reading = Session.running_turns

    assert_equal 0, reading.total
    assert_equal 0, reading.rows
  end

  test "only running rows are read" do
    session(status: :waiting)
    session(status: :needs_input)
    session(status: :failed)

    assert_equal 0, Session.running_turns.total
  end

  # The split #957 asked for. Both halves count toward the total — a queued turn
  # takes the next free worker, so it is committed demand — but the page has to
  # be able to say which is which.
  test "a running row splits into turns on a worker and turns queued for one" do
    working = session(running_job_id: SecureRandom.uuid)
    job_on_a_worker!(working.running_job_id)

    waiting_for_a_slot = session(running_job_id: SecureRandom.uuid)
    job_queued!(waiting_for_a_slot.running_job_id)

    reading = Session.running_turns

    assert_equal 1, reading.on_a_worker
    assert_equal 1, reading.queued_for_a_worker
    assert_equal 2, reading.total
  end

  # The handoff window: EnqueuedMessageProcessorService clears `running_job_id`
  # so the incoming job is not mistaken for a superseded one, and the session
  # sits between jobs until a worker takes the new one.
  test "a running row between jobs counts as queued, not as executing" do
    session(running_job_id: nil)

    reading = Session.running_turns

    assert_equal 0, reading.on_a_worker
    assert_equal 1, reading.queued_for_a_worker
    assert_equal 1, reading.total
  end

  # A finished job is not a worker on the session. The row is stale and
  # CleanupOrphanedSessionsJob is what repairs it, but it is not executing.
  test "a finished job does not count as a worker on the session" do
    stale = session(running_job_id: SecureRandom.uuid)
    job = job_on_a_worker!(stale.running_job_id)
    job.update!(finished_at: Time.current)

    assert_equal 0, Session.running_turns.on_a_worker
  end

  # THE REGRESSION. The session asked to sleep, its turn ended, and it stayed in
  # `running` because something else was already in flight for it. Every start
  # path refuses to start it before its wake, so the fleet cannot spend a worker
  # on it and it must not hold a slot in either ceiling.
  test "a running row asleep on a future wake with no worker is dropped from the total" do
    asleep = session(running_job_id: nil)
    arm_wake!(asleep)

    reading = Session.running_turns

    assert_equal 1, reading.asleep
    assert_equal 0, reading.total, "a session Zimmer refuses to start holds no slot"
    assert_equal 1, reading.rows, "#rows still reports every running row"
  end

  # The other half of the predicate, and the reason it is not "has a wake armed"
  # alone: arming a wake mid-turn is the ordinary orchestrator pattern, and that
  # session is at its busiest, not its idlest.
  test "a session that armed a wake mid-turn still counts while a worker is on it" do
    busy = session(running_job_id: SecureRandom.uuid)
    job_on_a_worker!(busy.running_job_id)
    arm_wake!(busy)

    reading = Session.running_turns

    assert_equal 0, reading.asleep
    assert_equal 1, reading.on_a_worker
    assert_equal 1, reading.total
  end

  # A wake whose moment has passed is not a pause any more — the session is due
  # to run, and the start paths no longer stand down for it.
  test "a wake that has come due does not drop the row" do
    due = session(running_job_id: nil)
    arm_wake!(due, at: 5.minutes.ago)

    assert_equal 0, Session.running_turns.asleep
    assert_equal 1, Session.running_turns.total
  end

  # Fail safe means COUNT it: the spot gate admits sessions on this reading and
  # FleetIdleMonitor spawns them, so a monitoring gap must never make the fleet
  # look emptier than it is.
  test "an unreadable agents queue counts every running turn as executing" do
    asleep = session(running_job_id: SecureRandom.uuid)
    arm_wake!(asleep)

    GoodJob::Job.stub(:where, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      reading = Session.running_turns

      assert_equal 1, reading.on_a_worker
      assert_equal 0, reading.asleep
      assert_equal 1, reading.total
    end
  end

  test "unreadable wake-up triggers count every running turn" do
    asleep = session(running_job_id: nil)
    arm_wake!(asleep)

    Session.stub(:ids_paused_until_scheduled_time, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      reading = Session.running_turns

      assert_equal 0, reading.asleep
      assert_equal 1, reading.total
    end
  end

  # Session.running_claude_code_count is the spot gate's fleet cap, and it is
  # runtime-scoped: a Codex session spends nothing against a Claude account.
  test "the Claude Code count is runtime scoped and reads through the same split" do
    claude = session(running_job_id: SecureRandom.uuid)
    job_on_a_worker!(claude.running_job_id)
    session(runtime: "codex", running_job_id: nil)

    asleep = session(running_job_id: nil)
    arm_wake!(asleep)

    assert_equal 1, Session.running_claude_code_count
    assert_equal 1, Session.running_claude_code_turns.on_a_worker
    assert_equal 1, Session.running_claude_code_turns.asleep
  end

  test "the Claude Code count reads as zero rather than raising when the fleet is unreadable" do
    Session.stub(:running_claude_code_turns, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "boom" }) do
      assert_equal 0, Session.running_claude_code_count
    end
  end

  # FleetIdleMonitor scopes the same reading the way Zimmer's recovery jobs do:
  # a `running` row in a frozen category is one nothing will ever repair.
  test "the fleet ceiling still skips frozen categories" do
    frozen = Category.create!(name: "Frozen #{SecureRandom.hex(3)}", is_frozen: true)
    parked = session(running_job_id: nil)
    parked.update!(category: frozen)

    session(running_job_id: nil)

    assert_equal 1, FleetIdleMonitor.running_sessions
    assert_equal 1, FleetIdleMonitor.running_turns.queued_for_a_worker
  end
end
