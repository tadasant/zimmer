# frozen_string_literal: true

require "test_helper"

# "Force": taking a worker thread off one turn and giving it to another.
#
# The two properties that matter are the two the feature is judged on. Who gets
# picked — the most recently started turn, minus the candidates where taking the
# thread would buy nothing or trample somebody else's record — and what happens
# to them: a turn that is stopped and PUT BACK, never a turn that is lost.
class Sessions::ForceTurnStartTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # The pool, shrunk so a test can saturate it with two sessions instead of
  # twelve. Every assertion about "the pool is full" is relative to this.
  SLOTS = 2

  setup do
    GoodJob::Process.delete_all
    GoodJob::Job.delete_all
    @capsule = GoodJob::Process.create!(state: { "hostname" => "worker-1" })
  end

  teardown do
    GoodJob::Job.delete_all
    GoodJob::Process.delete_all
  end

  def with_pool(&block) = RunningTurns.stub(:worker_slots, SLOTS, &block)

  def session_in(status, **attrs)
    Session.create!({
      git_root: "https://github.com/t/r.git",
      prompt: "work",
      status: status,
      session_id: "cli-#{SecureRandom.hex(4)}",
      genesis: SessionGenesis::WEB_UI
    }.merge(attrs))
  end

  # A turn a worker is executing: performed_at set, locked by a live capsule.
  def turn_on_a_worker(session, started: 1.minute.ago)
    GoodJob::Job.create!(
      queue_name: "agents", job_class: "AgentSessionJob", active_job_id: SecureRandom.uuid,
      serialized_params: { "job_class" => "AgentSessionJob", "arguments" => [ session.id ] },
      performed_at: started, locked_at: started, locked_by_id: @capsule.id
    )
  end

  # A turn sitting ready in the `agents` lane, which is what the Force button is
  # drawn for.
  def queued_turn(session, created: 30.seconds.ago)
    GoodJob::Job.create!(
      queue_name: "agents", job_class: "AgentSessionJob", active_job_id: SecureRandom.uuid,
      serialized_params: { "job_class" => "AgentSessionJob", "arguments" => [ session.id ] },
      created_at: created
    )
  end

  # The session doing the forcing: waiting, with a ready turn and no thread.
  def forcing_session
    session = session_in(:waiting)
    queued_turn(session)
    session
  end

  # A full pool: SLOTS running sessions, each on a thread, newest last.
  def saturate(count: SLOTS)
    count.times.map do |i|
      victim = session_in(:running)
      turn_on_a_worker(victim, started: (count - i).minutes.ago)
      victim
    end
  end

  # --- who gets picked -------------------------------------------------------

  test "the victim is the turn that started most recently" do
    oldest, newest = saturate
    session = forcing_session

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.forced?, result.message
      assert_equal newest.id, result.victim.id
      assert_equal :running, oldest.reload.status.to_sym, "the older turn was left alone"
    end
  end

  test "the forcing session is never its own victim" do
    saturate
    session = forcing_session

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.forced?, result.message
      assert_not_equal session.id, result.victim.id
      assert session.reload.waiting?, "the session doing the forcing was not stopped by its own click"
    end
  end

  test "a turn whose worker has died is not a victim — its thread is already gone" do
    dead = GoodJob::Process.create!(state: { "hostname" => "worker-2" })
    dead.update_column(:updated_at, (GoodJob::Process::EXPIRED_INTERVAL.to_i + 60).seconds.ago)

    stranded = session_in(:running)
    turn_on_a_worker(stranded, started: 1.second.ago).update_columns(locked_by_id: dead.id)
    alive_a, alive_b = saturate

    session = forcing_session

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.forced?, result.message
      assert_equal alive_b.id, result.victim.id
      assert_equal :running, stranded.reload.status.to_sym
      assert_equal :running, alive_a.reload.status.to_sym
    end
  end

  test "a worker still making the clone is not a victim — there is no process to stop" do
    # performed_at set, session still `waiting`: the pre-spawn window. It HOLDS a
    # thread, so it counts toward the pool being full, and it is still not
    # stoppable — Sessions::HaltRunningTurn would report `not_running` and the
    # thread would stay taken.
    setting_up = session_in(:waiting)
    turn_on_a_worker(setting_up, started: 1.second.ago)
    older = session_in(:running)
    turn_on_a_worker(older, started: 5.minutes.ago)

    session = forcing_session

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.forced?, result.message
      assert_equal older.id, result.victim.id
      assert setting_up.reload.waiting?
    end
  end

  test "a status-summary fork is not a victim — it has no conversation to put back" do
    fork = session_in(:running, metadata: { SessionStatusSummaryGenerator::FORK_MARKER => 1 })
    turn_on_a_worker(fork, started: 1.second.ago)
    older = session_in(:running)
    turn_on_a_worker(older, started: 5.minutes.ago)

    session = forcing_session

    with_pool do
      assert fork.status_summary_fork?, "fixture must actually be a fork"
      result = Sessions::ForceTurnStart.call(session)

      assert result.forced?, result.message
      assert_equal older.id, result.victim.id
    end
  end

  test "a session already carrying a spot pause record is not a victim" do
    # Its slot is already on its way back and SpotSessionPause's sweep is keyed on
    # that record; a second story written over it is a session with two owners.
    marked = session_in(:running, metadata: {
      SpotSessionPause::PAUSED_REASON => SpotSessionPause::PREEMPTED_REASON,
      SpotSessionPause::PAUSED_AT => 10.seconds.ago.iso8601
    })
    turn_on_a_worker(marked, started: 1.second.ago)
    older = session_in(:running)
    turn_on_a_worker(older, started: 5.minutes.ago)

    session = forcing_session

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.forced?, result.message
      assert_equal older.id, result.victim.id
    end
  end

  test "a session forced out inside the cooldown is passed over for the next candidate" do
    # The loop this exists to break: the session a force just re-queued picks up
    # the next free thread and is immediately the newest turn again.
    recent = session_in(:running, metadata: {
      Sessions::ForceTurnStart::FORCED_AT => 1.minute.ago.utc.iso8601
    })
    turn_on_a_worker(recent, started: 1.second.ago)
    older = session_in(:running)
    turn_on_a_worker(older, started: 5.minutes.ago)

    session = forcing_session

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.forced?, result.message
      assert_equal older.id, result.victim.id
    end
  end

  test "the cooldown expires and the session is a candidate again" do
    cooled = session_in(:running, metadata: {
      Sessions::ForceTurnStart::FORCED_AT =>
        (Sessions::ForceTurnStart::COOLDOWN + 1.minute).ago.utc.iso8601
    })
    turn_on_a_worker(cooled, started: 1.second.ago)
    turn_on_a_worker(session_in(:running), started: 5.minutes.ago)

    session = forcing_session

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.forced?, result.message
      assert_equal cooled.id, result.victim.id
    end
  end

  test "a session's class is not part of the rule — a priority session can be the victim" do
    # The request is purely recency-based, and implementing it as asked means a
    # priority session running the newest turn yields exactly as a spot one does.
    priority = session_in(:running, scheduling_class: SessionGenesis::PRIORITY)
    turn_on_a_worker(priority, started: 1.second.ago)
    turn_on_a_worker(session_in(:running, scheduling_class: SessionGenesis::SPOT), started: 5.minutes.ago)

    session = forcing_session

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.forced?, result.message
      assert_equal priority.id, result.victim.id
    end
  end

  # --- no eligible victim ----------------------------------------------------

  test "a pool with a free thread forces nothing and says the turn is already coming" do
    turn_on_a_worker(session_in(:running), started: 1.minute.ago)
    session = forcing_session

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.no_victim?, result.message
      assert_nil result.victim
      assert_match(/1 of Zimmer's #{SLOTS} worker threads are busy/, result.message)
      assert_match(/starts on GoodJob's next poll/, result.message)
    end
  end

  test "a full pool with nothing stoppable forces nothing and says so" do
    SLOTS.times do
      parked = session_in(:running, metadata: {
        SpotSessionPause::PAUSED_REASON => SpotSessionPause::UTILIZATION_REASON
      })
      turn_on_a_worker(parked, started: 1.minute.ago)
    end
    session = forcing_session

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.no_victim?, result.message
      assert_match(/all #{SLOTS} worker threads are busy/i, result.message)
      assert_match(/none of the turns on them can be stopped/, result.message)
    end
  end

  test "nothing running at all forces nothing" do
    session = forcing_session

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.no_victim?, result.message
      assert_match(/0 of Zimmer's #{SLOTS} worker threads are busy/, result.message)
    end
  end

  test "an unreadable agents queue forces nothing rather than guessing" do
    running = saturate
    session = forcing_session

    with_pool do
      GoodJob::Job.stub(:where, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
        result = Sessions::ForceTurnStart.call(session)

        assert_not result.forced?, "a read that failed is not evidence that a turn may be stopped"
      end
    end
    assert running.all? { |victim| victim.reload.running? },
      "no running session was stopped on the strength of a read that failed"
  end

  # --- what happens to the victim --------------------------------------------

  test "the victim's turn is stopped and put straight back in the agents queue" do
    _oldest, newest = saturate
    session = forcing_session

    with_pool do
      assert_enqueued_with(job: AgentSessionJob) do
        result = Sessions::ForceTurnStart.call(session)
        assert result.forced?, result.message
      end
    end

    newest.reload
    assert newest.waiting?, "the victim is dormant no longer than it takes to re-queue its turn"
    assert_nil newest.metadata["pending_sleep"], "the sleep intent was consumed, not left armed"
    args = enqueued_jobs.select { |job| job["job_class"] == "AgentSessionJob" }
                        .map { |job| ActiveJob::Arguments.deserialize(job["arguments"]) }
    assert_equal [ newest.id ], args.map(&:first), "exactly the victim's turn was re-enqueued"
    assert AutomatedPrompts.system_recovery?(args.first[1]),
      "the re-queued turn carries a nudge naming what happened"
    assert_match(/session #{session.id}/, args.first[1])
  end

  test "the victim's own record says it was forced out, and for whom" do
    _oldest, newest = saturate
    session = forcing_session

    with_pool { Sessions::ForceTurnStart.call(session) }

    metadata = newest.reload.metadata
    assert metadata[Sessions::ForceTurnStart::FORCED_AT].present?
    assert_equal session.id, metadata[Sessions::ForceTurnStart::FORCED_FOR_SESSION]
    assert_equal 1, metadata[Sessions::ForceTurnStart::FORCED_COUNT]
  end

  test "a halt that does not happen leaves no record claiming it did" do
    # The victim's turn ended between the pick and the halt — the commonest race
    # this can lose. Its row must not say it was forced out, or it would sit in
    # the cooldown for a force that never happened and point at a session that
    # never got the thread. An earlier, real force's record is put back intact.
    _oldest, newest = saturate
    newest.merge_metadata!(
      Sessions::ForceTurnStart::FORCED_AT => 1.hour.ago.utc.iso8601,
      Sessions::ForceTurnStart::FORCED_FOR_SESSION => 42,
      Sessions::ForceTurnStart::FORCED_COUNT => 2
    )
    session = forcing_session
    not_halted = Sessions::HaltRunningTurn::Result.new(halted: false, reason: :not_running)

    result = nil
    with_pool do
      Sessions::HaltRunningTurn.stub(:call, not_halted) do
        result = Sessions::ForceTurnStart.call(session)
      end
    end

    assert result.no_victim?, result.message
    assert_match(/could not be stopped/, result.message)
    metadata = newest.reload.metadata
    assert_equal 42, metadata[Sessions::ForceTurnStart::FORCED_FOR_SESSION]
    assert_equal 2, metadata[Sessions::ForceTurnStart::FORCED_COUNT]
    assert_operator Time.zone.parse(metadata[Sessions::ForceTurnStart::FORCED_AT]), :<, 30.minutes.ago
  end

  test "a halt that does not happen on a never-forced session leaves its row clean" do
    _oldest, newest = saturate
    session = forcing_session
    not_halted = Sessions::HaltRunningTurn::Result.new(halted: false, reason: :not_running)

    with_pool do
      Sessions::HaltRunningTurn.stub(:call, not_halted) do
        Sessions::ForceTurnStart.call(session)
      end
    end

    metadata = newest.reload.metadata || {}
    assert_nil metadata[Sessions::ForceTurnStart::FORCED_AT]
    assert_nil metadata[Sessions::ForceTurnStart::FORCED_FOR_SESSION]
    assert_nil metadata[Sessions::ForceTurnStart::FORCED_COUNT]
  end

  test "the force count accumulates across forces rather than resetting on the resume" do
    _oldest, newest = saturate
    newest.merge_metadata!(Sessions::ForceTurnStart::FORCED_COUNT => 3)
    session = forcing_session

    with_pool { Sessions::ForceTurnStart.call(session) }

    assert_equal 4, newest.reload.metadata[Sessions::ForceTurnStart::FORCED_COUNT]
  end

  test "both timelines name the other session" do
    _oldest, newest = saturate
    session = forcing_session

    with_pool { Sessions::ForceTurnStart.call(session) }

    assert newest.logs.any? { |log| log.content.include?("[Forced]") && log.content.include?("session #{session.id}") },
      "the victim's timeline says who took its thread"
    assert session.logs.any? { |log| log.content.include?("Session #{newest.id}'s turn was stopped") },
      "the forcing session's timeline says whose turn it took"
  end

  test "the forced turn is put at the head of the agents queue" do
    saturate
    session = session_in(:waiting)
    job = queued_turn(session)

    with_pool { Sessions::ForceTurnStart.call(session) }

    assert_equal Sessions::ForceTurnStart::FORCED_JOB_PRIORITY, job.reload.priority,
      "GoodJob dequeues `priority ASC NULLS LAST`, so a negative priority is what puts it first"
  end

  # --- refusals --------------------------------------------------------------

  test "a session with no queued turn is refused" do
    saturate
    session = session_in(:waiting)

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.refused?
      assert_match(/no turn queued for a worker/, result.message)
    end
  end

  test "a session whose turn already has a worker is refused" do
    saturate
    session = session_in(:waiting)
    turn_on_a_worker(session, started: 1.second.ago)

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.refused?
      assert_match(/already has a worker/, result.message)
    end
  end

  test "a running session is refused" do
    saturate
    session = session_in(:running)
    queued_turn(session)

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.refused?
      assert_match(/only a session queued for a worker can be forced/, result.message)
    end
  end

  test "an archived session is refused" do
    saturate
    session = session_in(:archived)
    queued_turn(session)

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.refused?
      assert_match(/in the trash/, result.message)
    end
  end

  test "a spot session is told the gate is still asked when a worker picks the turn up" do
    saturate
    session = session_in(:waiting, scheduling_class: SessionGenesis::SPOT)
    queued_turn(session)

    with_pool do
      result = Sessions::ForceTurnStart.call(session)

      assert result.forced?, result.message
      assert_match(/It stays spot/, result.message)
    end
  end

  # --- the preview the banner draws ------------------------------------------

  test "the preview names the victim and how long its turn has been running" do
    _oldest, newest = saturate
    session = forcing_session

    with_pool do
      preview = Sessions::ForceTurnStart.preview(session)

      assert preview.available?
      assert_equal newest.id, preview.victim.id
      assert_operator preview.victim_age, :>, 0
    end
  end

  test "the preview degrades to the reason there is nothing to force" do
    turn_on_a_worker(session_in(:running), started: 1.minute.ago)
    session = forcing_session

    with_pool do
      preview = Sessions::ForceTurnStart.preview(session)

      assert_not preview.available?
      assert_nil preview.victim
      assert_match(/Nothing to force/, preview.message)
    end
  end

  test "there is no preview at all for a session that is not queued for a worker" do
    saturate

    with_pool do
      assert_nil Sessions::ForceTurnStart.preview(session_in(:waiting))
      assert_nil Sessions::ForceTurnStart.preview(session_in(:running))
    end
  end
end
