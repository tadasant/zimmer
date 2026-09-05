# frozen_string_literal: true

require "test_helper"

# What `sessions.status = running` is worth as a measure of how busy the fleet is.
#
# A row lands in `running` the moment a turn is HANDED to a session, so the
# column holds turns being executed and turns queued behind the `agents` worker
# pool at the same time — plus, when a turn ends with something else already in
# flight, rows asleep on their own wake with nothing left to run them. Only the
# first of those three occupies the fleet, so `on_a_worker` is what both ceilings
# read and the other two are reported beside it.
class RunningTurnsTest < ActiveSupport::TestCase
  setup do
    # The fixtures ship sessions in every status, and every case here states its
    # own fleet.
    Session.delete_all
    GoodJob::Job.where(job_class: "AgentSessionJob").delete_all
  end

  def session(status: :running, runtime: ClaudeAuthProvider::RUNTIME)
    Session.create!(
      git_root: "https://github.com/tadasant/zimmer.git",
      prompt: "work",
      status: status,
      agent_runtime: runtime,
      session_id: SecureRandom.uuid
    )
  end

  # An AgentSessionJob row in the state a worker leaves it in while it is
  # performing: picked up (`performed_at`) and not yet done (`finished_at`).
  # `performed_at: nil` is the same row still sitting in the `agents` queue.
  def enqueue_turn!(session, performed_at: nil)
    GoodJob::Job.create!(
      active_job_id: SecureRandom.uuid, queue_name: "agents", job_class: "AgentSessionJob",
      serialized_params: { "arguments" => [ session.id ] },
      scheduled_at: 2.minutes.ago, performed_at: performed_at
    )
  end

  def on_a_worker!(session) = enqueue_turn!(session, performed_at: 1.minute.ago)

  test "an empty fleet reads as nothing in flight" do
    reading = Session.running_turns

    assert_equal 0, reading.on_a_worker
    assert_equal 0, reading.rows
  end

  test "only running rows are read" do
    [ :waiting, :needs_input, :failed ].each { |status| enqueue_turn!(session(status: status)) }

    assert_equal 0, Session.running_turns.rows
  end

  # THE CEILING CHANGE. A turn queued behind the `agents` pool is reported, but
  # it is not counted: it is occupying nothing, and a ceiling fed the depth of
  # the queue bounds how much work is waiting rather than how much is running.
  test "a turn queued for a worker is reported but not counted" do
    on_a_worker!(session)
    enqueue_turn!(session)

    reading = Session.running_turns

    assert_equal 1, reading.on_a_worker, "only the turn a worker started counts"
    assert_equal 1, reading.awaiting_a_worker
    assert_equal 2, reading.rows, "#rows still reports every running row"
  end

  # The same fleet, read through both ceilings: neither may fold the queue back
  # in. This is the arithmetic tadasant/zimmer#963 changed, asserted where an
  # operator sees it rather than only on the Reading.
  test "neither ceiling counts a turn that is only queued" do
    2.times { on_a_worker!(session) }
    3.times { enqueue_turn!(session) }

    assert_equal 2, Session.running_claude_code_count, "the spot gate's fleet cap"
    assert_equal 2, FleetIdleMonitor.running_sessions, "the backlog top-up ceiling"
    assert_equal 3, Session.running_turns.awaiting_a_worker, "and the queue is still reported"
  end

  # The handoff window: EnqueuedMessageProcessorService clears `running_job_id`
  # and the new job may not be enqueued yet. No worker is on it, so it does not
  # count — and `awaiting_a_worker` is the wider word for exactly this.
  test "a running row with no job at all reads as awaiting a worker" do
    session

    reading = Session.running_turns

    assert_equal 0, reading.on_a_worker
    assert_equal 1, reading.awaiting_a_worker
    assert_equal 0, reading.asleep
  end

  # A finished job is not a worker on the session, and it is not a turn coming
  # either. The row is one CleanupOrphanedSessionsJob repairs — and it still
  # counts, because that repair enqueues a turn.
  test "a finished job leaves the row awaiting a worker rather than executing" do
    stale = session
    enqueue_turn!(stale, performed_at: 5.minutes.ago).update!(finished_at: Time.current)

    reading = Session.running_turns

    assert_equal 0, reading.on_a_worker
    assert_equal 1, reading.awaiting_a_worker
  end

  # THE REGRESSION. The session asked to sleep, its turn ended, and it stayed in
  # `running` — but nothing is left to run it before its wake, so the fleet
  # cannot spend a worker on it and it must not hold a slot in either ceiling.
  test "a running row asleep on a future wake with nothing queued is not even awaiting a worker" do
    asleep = session
    arm_wake!(asleep, at: 20.minutes.from_now)

    reading = Session.running_turns

    assert_equal 1, reading.asleep
    assert_equal 0, reading.on_a_worker, "a session with nothing left to run it holds no slot"
    assert_equal 0, reading.awaiting_a_worker, "and no turn is coming for it either"
    assert_equal 1, reading.rows, "#rows still reports every running row"
  end

  # The half that is easy to get wrong, and the reason the rule is not "asleep"
  # alone. AgentSessionJob's pause guard is conjoined with `session.waiting?`, so
  # it does NOT stand down for a `running` row: the queued job will run the
  # session and take a worker.
  test "a sleeper with a turn already queued for it reads as awaiting a worker, not asleep" do
    asleep = session
    enqueue_turn!(asleep)
    arm_wake!(asleep, at: 20.minutes.from_now)

    reading = Session.running_turns

    assert_equal 0, reading.asleep
    assert_equal 1, reading.awaiting_a_worker
  end

  # The other half, and the reason it is not "has a wake armed" alone: arming a
  # wake mid-turn is the ordinary orchestrator pattern, and that session is at
  # its busiest, not its idlest.
  test "a session that armed a wake mid-turn still counts while a worker is on it" do
    busy = session
    on_a_worker!(busy)
    arm_wake!(busy, at: 20.minutes.from_now)

    reading = Session.running_turns

    assert_equal 0, reading.asleep
    assert_equal 1, reading.on_a_worker
  end

  # A wake whose moment has passed is not a pause any more — the session is due
  # to run, and the start paths no longer stand down for it.
  test "a wake that has come due does not drop the row" do
    arm_wake!(session, at: 5.minutes.ago)

    assert_equal 0, Session.running_turns.asleep
    assert_equal 1, Session.running_turns.awaiting_a_worker
  end

  # Fail safe means COUNT it, and this is the rescue the ceilings ride on now
  # that `on_a_worker` is the whole count: the spot gate admits sessions on this
  # reading and FleetIdleMonitor spawns them, so a monitoring gap must never make
  # the fleet look emptier than it is. Deliberately a non-ActiveRecord error,
  # since the rescues are what stop one escaping into the gate.
  test "an unreadable agents queue counts every running turn as executing" do
    asleep = session
    arm_wake!(asleep, at: 20.minutes.from_now)
    enqueue_turn!(session)

    PendingAgentTurns.stub(:split, ->(*) { raise TypeError, "boom" }) do
      reading = Session.running_turns

      assert_equal 2, reading.on_a_worker, "every row counts when the queue cannot be read"
      assert_equal 0, reading.awaiting_a_worker
      assert_equal 0, reading.asleep
    end
  end

  # The other rescue can no longer move the counted number in either direction —
  # both populations it decides between are uncounted — so what it protects is
  # the reported split, and the fact that nothing escapes into the spot gate.
  test "unreadable wake-up triggers report every uncounted row as a turn still coming" do
    asleep = session
    arm_wake!(asleep, at: 20.minutes.from_now)

    Session.stub(:ids_paused_until_scheduled_time, ->(*) { raise TypeError, "boom" }) do
      reading = Session.running_turns

      assert_equal 0, reading.asleep
      assert_equal 1, reading.awaiting_a_worker
      assert_equal 0, reading.on_a_worker
    end
  end

  # Session.running_claude_code_count is the spot gate's fleet cap, and it is
  # runtime-scoped: a Codex session spends nothing against a Claude account.
  test "the Claude Code count is runtime scoped and reads through the same split" do
    on_a_worker!(session)
    on_a_worker!(session(runtime: "codex"))

    asleep = session
    arm_wake!(asleep, at: 20.minutes.from_now)

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
    on_a_worker!(session.tap { |s| s.update!(category: frozen) })
    on_a_worker!(session)

    assert_equal 1, FleetIdleMonitor.running_sessions
    assert_equal 1, FleetIdleMonitor.running_turns.on_a_worker
  end

  test "the worker-slot ceiling is the agents lane's own thread count" do
    assert_equal ConnectionBudget.good_job_queue_threads[:agents], RunningTurns.worker_slots
  end

  # The consequence of counting worker occupancy alone: the counted population
  # cannot exceed the pool, so a ceiling above it is one the fleet never reaches.
  # Both /inference cards and `get_spot_policy` render the note off these two.
  test "a ceiling above the worker pool is out of reach, and the effective one is the pool" do
    slots = RunningTurns.worker_slots

    assert RunningTurns.ceiling_out_of_reach?(slots + 1)
    refute RunningTurns.ceiling_out_of_reach?(slots)
    refute RunningTurns.ceiling_out_of_reach?(slots - 1)

    assert_equal slots, RunningTurns.effective_ceiling(slots + 5)
    assert_equal slots - 1, RunningTurns.effective_ceiling(slots - 1)
  end
end
