require "test_helper"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_file_system_adapter"
require_relative "../support/mock_claude_cli_adapter"

# The reproduction, at the level the bug actually happened: a monitoring job
# told to re-attach to a pid that is gone.
#
# Production sessions 12265 and 12267 were caught by the same worker interruption on
# 2026-09-02. Both had their recovery job fail to adopt a dead pid; both were parked
# with `paused_by: "recovery"`; both then sat there until an unrelated orphan sweep
# reached them nine and a half minutes later. The difference the old code could not
# see is the one these tests are about — 12265 had produced transcript output and was
# resumed harmlessly, 12267 had produced nothing at all and should never have been
# parked in the first place.
class AgentSessionJobUnstartedRestartTest < ActiveJob::TestCase
  CLONE = "/tmp/unstarted-restart-clone"

  setup do
    @session = Session.create!(
      prompt: "Ship the thing",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: "550e8400-e29b-41d4-a716-446655440000",
      transcript: nil,
      metadata: {
        "process_pid" => 73_925,
        "clone_path" => CLONE,
        "working_directory" => CLONE,
        "runtime_started" => true
      }
    )
  end

  # A monitoring job whose pid is already dead, wired exactly as the recovery path
  # wires it (AgentSessionJob.enqueue_for_monitoring).
  def perform_dead_pid_recovery
    job = AgentSessionJob.new
    mock_pm = MockProcessManager.new
    mock_pm.running_hook = ->(_pid) { false }
    mock_fs = MockFileSystemAdapter.new
    mock_fs.mkdir_p(CLONE)
    job.process_manager = mock_pm
    job.file_system = mock_fs
    job.cli_adapter = MockClaudeCliAdapter.new

    job.perform(@session.id, nil, resume_monitoring: true, monitor_pid: 73_925)
    @session.reload
  end

  def conversation_transcript
    { "type" => "user", "message" => { "content" => "Ship the thing" } }.to_json
  end

  # ---------------------------------------------------------------------------
  # (a) process dead + zero transcript output -> respawn from the stored prompt
  # ---------------------------------------------------------------------------

  test "a session that never produced a turn is restarted from its own prompt, not parked" do
    assert_enqueued_with(job: AgentSessionJob) { perform_dead_pid_recovery }

    assert_equal "running", @session.status,
      "session 12267's whole problem was coming to rest in the human action queue having done nothing"
    assert_nil @session.metadata["paused_by"],
      "a restarted session is not waiting for a recovery sweep"
    assert_equal "Ship the thing", @session.metadata["pending_follow_up_prompt"],
      "the stored prompt is exactly the work that never happened"
    assert_not_nil @session.running_job_id,
      "the failed recovery must leave a queued job behind it (D2)"
    assert @session.logs.any? { |l| l.content.include?("restarting this turn from the session's own prompt") },
      "the decision must be legible on the session's own timeline"
  end

  test "the restart does not wait for the orphan sweep" do
    perform_dead_pid_recovery

    restart = enqueued_jobs.find { |j| j["job_class"] == "AgentSessionJob" }
    assert_not_nil restart, "the restart must be queued by this job, not by a five-minute cron"
    assert_nil restart["scheduled_at"], "the replacement turn runs now, not on a delay"
  end

  # ---------------------------------------------------------------------------
  # (b) process dead + existing transcript output -> resumed, never restarted
  # ---------------------------------------------------------------------------

  test "a session with real transcript content is still parked for the resume-with-nudge path" do
    @session.update!(transcript: conversation_transcript)

    perform_dead_pid_recovery

    assert_equal "needs_input", @session.status
    assert_equal "recovery", @session.metadata["paused_by"],
      "the marker both recovery sweeps select on must survive"
    assert_nil @session.metadata["pending_follow_up_prompt"],
      "session 12265's conversation must be resumed, never restarted from scratch"
    assert_equal true, @session.metadata["runtime_started"],
      "clearing runtime_started here would turn the next resume into a fresh spawn"
  end

  test "a parked session gets its continuation asked for directly rather than waiting on the cron" do
    @session.update!(transcript: conversation_transcript)

    assert_enqueued_with(job: RecoveryContinuationJob, args: [ @session.id ]) do
      perform_dead_pid_recovery
    end
  end

  # ---------------------------------------------------------------------------
  # the cap
  # ---------------------------------------------------------------------------

  test "a session that stays empty across the whole budget comes to rest saying so" do
    @session.merge_metadata!(
      Sessions::RestartUnstartedTurn::COUNT_KEY => Sessions::RestartUnstartedTurn::MAX_RESTARTS
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      perform_dead_pid_recovery
    end

    assert_equal "needs_input", @session.status
    assert_nil @session.metadata["paused_by"],
      "handing an unrestartable session to twelve doomed auto-continue attempts helps nobody"
    assert_equal "unstarted_turn_not_recoverable", @session.metadata["failure_reason"]
    assert_present @session.metadata[Sessions::RestartUnstartedTurn::ABANDONED_KEY]
    assert @session.logs.any? { |l| l.content.include?("Not restarting this turn again") }
  end

  test "the restart budget is spent one attempt at a time" do
    perform_dead_pid_recovery
    assert_equal 1, @session.metadata[Sessions::RestartUnstartedTurn::COUNT_KEY]

    # The replacement turn dies the same way, and so does the one after it.
    Sessions::RestartUnstartedTurn::MAX_RESTARTS.times do
      @session.update!(status: :running, metadata: @session.metadata.merge(
        "process_pid" => 73_925, "clone_path" => CLONE, "working_directory" => CLONE
      ))
      perform_dead_pid_recovery
    end

    assert_equal "needs_input", @session.status
    assert_equal Sessions::RestartUnstartedTurn::MAX_RESTARTS,
      @session.metadata[Sessions::RestartUnstartedTurn::COUNT_KEY]
    assert_present @session.metadata[Sessions::RestartUnstartedTurn::ABANDONED_KEY]
  end

  private

  def assert_present(value)
    assert value.present?, "expected #{value.inspect} to be present"
  end
end
