require "test_helper"

class AgentJobIntentTest < ActiveJob::TestCase
  setup do
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "process_pid" => 4242, "clone_path" => "/tmp/test-clone" }
    )
  end

  test "a job enqueued for monitoring is monitor-only" do
    job = AgentSessionJob.enqueue_for_monitoring(@session.id, monitor_pid: 4242)

    assert AgentJobIntent.monitor_only?(job.job_id)
  end

  test "a job enqueued to spawn a turn is not monitor-only" do
    job = AgentSessionJob.enqueue_with_prompt(@session.id, "keep going")

    assert_not AgentJobIntent.monitor_only?(job.job_id)
  end

  test "a clone-only job is not monitor-only" do
    job = AgentSessionJob.enqueue_for_clone_only(@session.id)

    assert_not AgentJobIntent.monitor_only?(job.job_id)
  end

  test "an unknown job id is not monitor-only" do
    assert_not AgentJobIntent.monitor_only?("no-such-job")
  end

  test "a blank job id is not monitor-only" do
    assert_not AgentJobIntent.monitor_only?(nil)
    assert_not AgentJobIntent.monitor_only?("")
  end

  # Production reads the intent out of `good_jobs`, where the arguments arrive as a
  # serialized hash rather than as the in-memory job object the test adapter keeps.
  test "reads the intent from a persisted GoodJob row" do
    active_job_id = SecureRandom.uuid
    GoodJob::Job.create!(
      active_job_id: active_job_id,
      job_class: "AgentSessionJob",
      queue_name: "agents",
      serialized_params: {
        "job_class" => "AgentSessionJob",
        "job_id" => active_job_id,
        "arguments" => [ @session.id, nil, { "resume_monitoring" => true, "monitor_pid" => 4242 } ]
      }
    )

    assert AgentJobIntent.monitor_only?(active_job_id)
  end

  test "a persisted GoodJob row for a spawning job is not monitor-only" do
    active_job_id = SecureRandom.uuid
    GoodJob::Job.create!(
      active_job_id: active_job_id,
      job_class: "AgentSessionJob",
      queue_name: "agents",
      serialized_params: {
        "job_class" => "AgentSessionJob",
        "job_id" => active_job_id,
        "arguments" => [ @session.id, "keep going" ]
      }
    )

    assert_not AgentJobIntent.monitor_only?(active_job_id)
  end
end
