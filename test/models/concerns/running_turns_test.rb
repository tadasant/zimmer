# frozen_string_literal: true

require "test_helper"

# What `sessions.status = running` is worth as a measure of how busy the fleet is.
#
# The property under test is the one #957 was about: a row lands in `running` the
# moment a turn is HANDED to a session, so the column holds turns being executed
# and turns queued behind the `agents` worker pool at the same time — plus, when
# a turn ends with something else already in flight, rows that are asleep on
# their own wake with nothing left to run them.
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

    assert_equal 0, reading.total
    assert_equal 0, reading.rows
  end

  test "only running rows are read" do
    [ :waiting, :needs_input, :failed ].each { |status| enqueue_turn!(session(status: status)) }

    assert_equal 0, Session.running_turns.total
  end

  # The split #957 asked for. Both halves count toward the total — a turn queued
  # for a worker takes the next free slot, so it is committed demand — but the
  # page has to be able to say which is which.
  test "a running row splits into turns on a worker and turns waiting for one" do
    on_a_worker!(session)
    enqueue_turn!(session)

    reading = Session.running_turns

    assert_equal 1, reading.on_a_worker
    assert_equal 1, reading.awaiting_a_worker
    assert_equal 2, reading.total
  end

  # The handoff window: EnqueuedMessageProcessorService clears `running_job_id`
  # and the new job may not be enqueued yet. The row counts, because something is
  # about to run it — and `awaiting_a_worker` is the wider word for exactly this.
  test "a running row with no job at all counts as awaiting a worker" do
    session

    reading = Session.running_turns

    assert_equal 0, reading.on_a_worker
    assert_equal 1, reading.awaiting_a_worker
    assert_equal 1, reading.total
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
  test "a running row asleep on a future wake with nothing queued is dropped from the total" do
    asleep = session
    arm_wake!(asleep, at: 20.minutes.from_now)

    reading = Session.running_turns

    assert_equal 1, reading.asleep
    assert_equal 0, reading.total, "a session with nothing left to run it holds no slot"
    assert_equal 1, reading.rows, "#rows still reports every running row"
  end

  # The half that is easy to get wrong, and the reason the rule is not "asleep"
  # alone. AgentSessionJob's pause guard is conjoined with `session.waiting?`, so
  # it does NOT stand down for a `running` row: the queued job will run the
  # session and take a worker.
  test "a sleeper with a turn already queued for it still counts" do
    asleep = session
    enqueue_turn!(asleep)
    arm_wake!(asleep, at: 20.minutes.from_now)

    reading = Session.running_turns

    assert_equal 0, reading.asleep
    assert_equal 1, reading.awaiting_a_worker
    assert_equal 1, reading.total
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
    assert_equal 1, reading.total
  end

  # A wake whose moment has passed is not a pause any more — the session is due
  # to run, and the start paths no longer stand down for it.
  test "a wake that has come due does not drop the row" do
    arm_wake!(session, at: 5.minutes.ago)

    assert_equal 0, Session.running_turns.asleep
    assert_equal 1, Session.running_turns.total
  end

  # Fail safe means COUNT it: the spot gate admits sessions on this reading and
  # FleetIdleMonitor spawns them, so a monitoring gap must never make the fleet
  # look emptier than it is. Deliberately a non-ActiveRecord error, since the
  # rescues are what stop one escaping into the gate.
  test "an unreadable agents queue counts every running turn as executing" do
    asleep = session
    arm_wake!(asleep, at: 20.minutes.from_now)

    PendingAgentTurns.stub(:split, ->(*) { raise TypeError, "boom" }) do
      reading = Session.running_turns

      assert_equal 1, reading.on_a_worker
      assert_equal 0, reading.asleep
      assert_equal 1, reading.total
    end
  end

  test "unreadable wake-up triggers count every running turn" do
    asleep = session
    arm_wake!(asleep, at: 20.minutes.from_now)

    Session.stub(:ids_paused_until_scheduled_time, ->(*) { raise TypeError, "boom" }) do
      reading = Session.running_turns

      assert_equal 0, reading.asleep
      assert_equal 1, reading.total
    end
  end

  # Session.running_claude_code_count is the spot gate's fleet cap, and it is
  # runtime-scoped: a Codex session spends nothing against a Claude account.
  test "the Claude Code count is runtime scoped and reads through the same split" do
    on_a_worker!(session)
    session(runtime: "codex")

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
    session.update!(category: frozen)
    session

    assert_equal 1, FleetIdleMonitor.running_sessions
    assert_equal 1, FleetIdleMonitor.running_turns.awaiting_a_worker
  end

  test "the worker-slot ceiling is the agents lane's own thread count" do
    assert_equal ConnectionBudget.good_job_queue_threads[:agents], RunningTurns.worker_slots
  end
end
