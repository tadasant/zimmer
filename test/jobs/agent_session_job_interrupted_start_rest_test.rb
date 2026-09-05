# frozen_string_literal: true

require "test_helper"

# Where an interrupted start comes to rest (tadasant/zimmer#602).
#
# `handle_interrupt_error` has three answers for a session whose job was
# interrupted, and the third — the ordinary recovery pause — writes
# `paused_by: "recovery"`, pauses to `needs_input` and asks
# `auto_continue_after_interrupt` to pick the session straight back up. That
# continuation needs a runtime session to resume, and a session interrupted
# before it issued one has none. It declined, and the session stayed in the human
# action queue with an empty transcript and nothing to ask: twelve doomed sweep
# attempts (about an hour) before the sweeps' own give-up abandoned it there for
# good.
#
# ~28 spot sessions were left like that by one interruption window on
# 2026-08-20, each carrying `interrupted_start_requeue_count`, a `job_started_at`
# and a transcript holding only the spawn prompt.
class AgentSessionJobInterruptedStartRestTest < ActiveJob::TestCase
  setup do
    @session = Session.create!(
      prompt: "Ship the thing",
      agent_runtime: "codex",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      # A runtime that mints its own rollout id leaves Zimmer's column blank until
      # transcript polling reads one back, so this is what "spawned, never wrote a
      # line" looks like on the row.
      session_id: nil,
      transcript: nil,
      metadata: { "job_started_at" => 30.seconds.ago.utc.iso8601 }
    )
  end

  def interrupt!
    job = AgentSessionJob.new(@session.id)
    @session.update!(running_job_id: job.job_id)
    job.send(
      :handle_interrupt_error,
      GoodJob::InterruptError.new("Interrupted after starting perform at '2026-08-20 19:14:00 UTC'")
    )
    @session.reload
  end

  test "an interrupted session with no runtime session to resume comes to rest in waiting" do
    interrupt!

    assert_equal "waiting", @session.status,
      "a session with nothing to resume is waiting for compute, not for a human"
    assert_nil @session.metadata["paused_by"],
      "the recovery marker has to go with the move, or both sweeps keep chasing it"
    assert_equal 1, @session.metadata[Sessions::ReturnToQueue::COUNT_KEY]
    assert @session.logs.any? { |log| log.content.include?("Returning it to the queue") }
  end

  # `waiting` is only the right answer if something reads `waiting`.
  test "the returned session is back in the population the stalled-start sweep restarts" do
    interrupt!
    @session.update_columns(created_at: 1.hour.ago, updated_at: 1.hour.ago)

    assert_includes StalledSessionStart.stalled_sessions.to_a, @session.reload
  end

  # The guard. An interrupted session that HAS a runtime session behind it is the
  # case the recovery pause was written for, and it keeps every bit of that
  # handling: the marker stays on, and the sweeps own it from here.
  test "an interrupted session with a runtime session to resume keeps the recovery pause" do
    @session.update!(session_id: SecureRandom.uuid, metadata: (@session.metadata || {}).merge(
      "working_directory" => "/nonexistent-clone-#{SecureRandom.hex(4)}"
    ))

    interrupt!

    assert_equal "needs_input", @session.status,
      "a session with a conversation to resume must not be silently re-dispatched"
    assert_equal "recovery", @session.metadata["paused_by"]
    assert_nil @session.metadata[Sessions::ReturnToQueue::COUNT_KEY]
  end

  # And the interrupted-at-start replay itself is untouched: a session still
  # `waiting` when the interrupt lands is re-queued rather than parked, which is
  # the half of this that was already right.
  test "a session interrupted before it left waiting is re-queued, not parked" do
    @session.update!(status: :waiting)

    assert_enqueued_with(job: AgentSessionJob) { interrupt! }

    assert_equal "waiting", @session.status
    assert_equal 1, @session.metadata[AgentSessionJob::INTERRUPTED_START_REQUEUE_COUNT]
    assert_nil @session.metadata[Sessions::ReturnToQueue::COUNT_KEY],
      "the replay owns this case; the rest-state repair must not also fire on it"
  end

  # The loop both bounds exist to stop. The replay budget still fails a start job
  # that can never survive, rather than re-queueing it forever.
  test "the interrupted-start replay budget still fails a session that can never start" do
    @session.update!(
      status: :waiting,
      metadata: (@session.metadata || {}).merge(
        AgentSessionJob::INTERRUPTED_START_REQUEUE_COUNT => AgentSessionJob::MAX_INTERRUPTED_START_REQUEUES
      )
    )

    assert_no_enqueued_jobs(only: AgentSessionJob) { interrupt! }

    assert @session.failed?, "expected a loud failure, got #{@session.status}"
    assert_includes @session.metadata["failure_reason"], "never started"
  end
end
