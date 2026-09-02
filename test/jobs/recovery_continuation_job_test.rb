require "test_helper"

# The prompt half of the prod 12265/12267 stall: a recovery pause promises a sweep
# will continue the session, and a five-minute cron alone keeps that promise slowly.
class RecoveryContinuationJobTest < ActiveJob::TestCase
  setup do
    @clone_path = Dir.mktmpdir("recovery_continuation_job_test")
    @session = Session.create!(
      prompt: "Ship the thing",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => @clone_path,
        "working_directory" => @clone_path,
        "paused_by" => "recovery"
      }
    )
  end

  teardown do
    FileUtils.rm_rf(@clone_path) if @clone_path && Dir.exist?(@clone_path)
  end

  test "continues a recovery-paused session" do
    assert_enqueued_with(job: AgentSessionJob) do
      RecoveryContinuationJob.perform_now(@session.id)
    end

    @session.reload
    assert_equal "running", @session.status
    assert_nil @session.metadata["paused_by"], "resuming clears the marker the sweeps select on"
    assert @session.logs.any? { |l| l.content.include?("automatically continued after recovery retry") }
  end

  test "does nothing for a session a human or another sweep already resumed" do
    @session.update!(status: :running, metadata: @session.metadata.except("paused_by"))

    assert_no_enqueued_jobs only: AgentSessionJob do
      RecoveryContinuationJob.perform_now(@session.id)
    end
  end

  test "does nothing for a session that was archived in the delay window" do
    @session.update!(status: :archived)

    assert_no_enqueued_jobs only: AgentSessionJob do
      RecoveryContinuationJob.perform_now(@session.id)
    end

    assert_equal "archived", @session.reload.status
  end

  test "leaves a frozen category alone, as both sweeps do" do
    category = Category.create!(name: "Frozen #{SecureRandom.hex(4)}", is_frozen: true)
    @session.update!(category: category)

    assert_no_enqueued_jobs only: AgentSessionJob do
      RecoveryContinuationJob.perform_now(@session.id)
    end

    assert_equal "needs_input", @session.reload.status
  end

  test "does nothing for a session that no longer exists" do
    id = @session.id
    @session.destroy!

    assert_nothing_raised { RecoveryContinuationJob.perform_now(id) }
  end

  test "schedule_for queues the continuation on a short delay" do
    assert_enqueued_with(job: RecoveryContinuationJob, args: [ @session.id ]) do
      RecoveryContinuationJob.schedule_for(@session)
    end

    queued = enqueued_jobs.find { |j| j["job_class"] == "RecoveryContinuationJob" }
    assert_not_nil queued["scheduled_at"], "the delay is what lets the parking writes commit first"
  end

  test "schedule_for never raises out of the recovery path it is called from" do
    RecoveryContinuationJob.stub(:set, ->(*) { raise "queue is down" }) do
      assert_nothing_raised { RecoveryContinuationJob.schedule_for(@session) }
    end
  end

  test "a session it cannot continue still counts against the shared attempt budget" do
    # No working directory on disk: SessionContinuation's validation refuses, and the
    # bound that stops the cron sweeping forever must bound this job too.
    @session.merge_metadata!("working_directory" => "/tmp/definitely-not-there-#{SecureRandom.hex(4)}")

    assert_no_enqueued_jobs only: AgentSessionJob do
      RecoveryContinuationJob.perform_now(@session.id)
    end

    assert_equal 1, @session.reload.metadata[SessionContinuation::CONTINUE_ATTEMPTS_KEY]
  end
end
