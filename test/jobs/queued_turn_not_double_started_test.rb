# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# A turn that has been handed over but not yet started must not be started twice.
#
# THE HAZARD #1040 CREATED, and the guard that closes it. Before that change a
# session with a turn in flight read `running`, and `running` is the one status
# `resume` is refused from — so `may_resume?` alone answered "is somebody else
# already driving this session". Now a handed-over turn reads `waiting`, which is
# also what a spot hold, a quota park and an ordinary sleep read, so `may_resume?`
# says yes to a session whose job is already sitting in the `agents` queue.
#
# Acting on that would be #400 arriving from a new direction: two AgentSessionJobs
# against one clone, two agent processes on one conversation, and real quota spent
# re-delivering a prompt.
#
# The honest test is the job row, not the status column — `running_job_id` is
# written from INSIDE `AgentSessionJob#perform`, so a queued turn has a blank one
# (see PendingAgentTurns). Three layers read it, and each is pinned here.
class QueuedTurnNotDoubleStartedTest < ActiveJob::TestCase
  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
    GoodJob::Job.where(job_class: "AgentSessionJob").delete_all
    GoodJob::Process.delete_all
    @working_directory = Dir.mktmpdir("queued-turn")
  end

  teardown do
    Mocha::Mockery.instance.teardown
    GoodJob::Process.delete_all
    FileUtils.remove_entry(@working_directory) if @working_directory && Dir.exist?(@working_directory)
  end

  def recovery_paused_session(status: :waiting)
    Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid,
      status: status,
      running_job_id: nil,
      metadata: {
        "clone_path" => @working_directory,
        "working_directory" => @working_directory,
        "paused_by" => "recovery"
      }
    )
  end

  # The row a real `perform_later` writes: ready in the `agents` lane, unclaimed,
  # and — crucially — with no `running_job_id` on the session, which is exactly the
  # shape that used to read as "nothing is driving this session".
  def queue_a_turn_for(session, **attrs)
    GoodJob::Job.create!({
      active_job_id: SecureRandom.uuid, queue_name: "agents", job_class: "AgentSessionJob",
      serialized_params: { "arguments" => [ session.id ] }, scheduled_at: 1.minute.ago
    }.merge(attrs))
  end

  # === Session#claim_system_recovery_turn! ===================================

  test "a waiting session with a turn already queued refuses the claim" do
    session = recovery_paused_session
    queue_a_turn_for(session)

    assert session.may_resume?, "precondition: the state machine alone would allow this"

    assert_equal :not_resumable, session.claim_system_recovery_turn!
    assert session.reload.waiting?, "a refused claim writes nothing at all"
  end

  test "a waiting session with a turn a worker already has refuses the claim" do
    session = recovery_paused_session
    # What GoodJob writes when a capsule picks a job up: `performed_at` plus the
    # lock. `JobLiveness` needs both — `performed_at` alone is a corpse whose
    # worker died, which is not a turn to stand down behind.
    capsule = GoodJob::Process.create!(state: { "hostname" => "worker-1" })
    queue_a_turn_for(session, performed_at: 30.seconds.ago,
                     locked_at: 30.seconds.ago, locked_by_id: capsule.id)

    assert_equal :not_resumable, session.claim_system_recovery_turn!
  end

  # The other half of that: a job with `performed_at` and no live lock is a worker
  # that died mid-turn, and standing down behind it would strand the session — the
  # exact failure the recovery sweeps exist to end.
  test "a waiting session whose turn lost its worker is still claimed" do
    session = recovery_paused_session
    queue_a_turn_for(session, performed_at: 30.seconds.ago)

    assert_equal :claimed, session.claim_system_recovery_turn!
  end

  test "a waiting session with nothing queued is claimed" do
    session = recovery_paused_session

    assert_equal :claimed, session.claim_system_recovery_turn!
    assert session.reload.waiting?, "the claim hands a turn over; a worker's `start` runs it"
  end

  # A job parked on a future `scheduled_at` is a spot-gate re-check or a clone
  # backoff. Refusing on one would leave a recovery-paused session unrecoverable
  # for as long as the ladder ran, so the claim only defers to a turn that is
  # actually underway.
  test "a turn deferred to the future does not refuse the claim" do
    session = recovery_paused_session
    queue_a_turn_for(session, scheduled_at: 30.minutes.from_now)

    assert_equal :claimed, session.claim_system_recovery_turn!
  end

  # The interrupt path reaches the claim with the session in `needs_input` and the
  # job it was interrupted on not yet finished. Asking the job rows there would
  # refuse the immediate auto-continue that closes the deploy-interrupt window, so
  # the queued-turn refusal is scoped to `waiting`.
  test "a needs_input session is judged by the state machine alone" do
    session = recovery_paused_session(status: :needs_input)
    capsule = GoodJob::Process.create!(state: { "hostname" => "worker-1" })
    queue_a_turn_for(session, performed_at: 30.seconds.ago,
                     locked_at: 30.seconds.ago, locked_by_id: capsule.id)

    assert_equal :claimed, session.claim_system_recovery_turn!
  end

  # === the recovery sweeps ===================================================

  test "the orphan sweep does not enqueue a second turn for a session that has one queued" do
    session = recovery_paused_session
    queue_a_turn_for(session)

    assert_no_enqueued_jobs only: AgentSessionJob do
      assert_equal false, CleanupOrphanedSessionsJob.new.send(:continue_recovered_session, session)
    end

    assert session.logs.reload.any? { |log| log.content.include?("Something else is already driving it") },
      "the refusal has to be on the session's own timeline, where 'why did nothing happen' is asked"
  end

  test "the orphan sweep does start a session that genuinely has nothing queued" do
    session = recovery_paused_session

    assert_enqueued_with(job: AgentSessionJob) do
      assert CleanupOrphanedSessionsJob.new.send(:continue_recovered_session, session)
    end
  end

  # === the queued-message drain ==============================================
  #
  # The drain reads `waiting` as "idle" (Session#idle_for_queued_delivery?) and
  # stood down on `running_job_id` alone, which is BLANK for a queued turn: the
  # three paths that resume through a claim all write `running_job_id: nil` and
  # then enqueue without recording one. So a queued turn was invisible to it.

  test "the drain does not deliver into a session whose turn is already queued" do
    session = recovery_paused_session
    session.remove_metadata!("paused_by")
    session.enqueued_messages.create!(content: "a queued message", position: 1)
    queue_a_turn_for(session)

    assert_equal "a turn is already queued for a worker",
      EnqueuedMessageDrainJob.new.send(:skip_reason, session.reload)
  end

  test "the drain does deliver into a session that is genuinely idle" do
    session = recovery_paused_session
    session.remove_metadata!("paused_by")
    session.enqueued_messages.create!(content: "a queued message", position: 1)

    assert_nil EnqueuedMessageDrainJob.new.send(:skip_reason, session.reload)
  end

  # === the dispatch sweeps ===================================================
  #
  # These two read `waiting` directly and are the population most exposed by the
  # change, since a queued turn now sits in exactly the state they select. Both
  # already anti-join `good_jobs` — this pins that they keep doing it.

  test "the stalled-start sweep does not see a waiting session with a turn queued" do
    session = Session.create!(
      prompt: "Test prompt", agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git", status: :waiting,
      created_at: 2.hours.ago, updated_at: 2.hours.ago
    )
    assert_includes StalledSessionStart.stalled_sessions.map(&:id), session.id,
      "precondition: with nothing queued it is a stalled start"

    queue_a_turn_for(session)

    assert_not_includes StalledSessionStart.stalled_sessions.map(&:id), session.id
  end

  test "the stranded-sleep sweep does not see a waiting session with a turn queued" do
    session = Session.create!(
      prompt: "Test prompt", agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git", status: :waiting,
      session_id: SecureRandom.uuid
    )
    session.update_columns(updated_at: 2.hours.ago)
    assert_includes StrandedSleepRescue.candidates.map(&:id), session.id,
      "precondition: with nothing queued it is a candidate"

    queue_a_turn_for(session)

    assert_not_includes StrandedSleepRescue.candidates.map(&:id), session.id
  end
end
