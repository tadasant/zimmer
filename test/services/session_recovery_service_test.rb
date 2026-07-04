require "test_helper"
require "minitest/mock"

class SessionRecoveryServiceTest < ActiveJob::TestCase
  setup do
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "process_pid" => 12345, "clone_path" => "/tmp/test-clone" }
    )

    @mock_process_manager = MockProcessManager.new
  end

  test "recover with running process enqueues recovery job" do
    # Create a mock process manager that reports the process as running
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| pid == 12345 }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm, skip_pid_check: false)

    # Check that a job is enqueued
    assert_enqueued_with(job: AgentSessionJob) do
      result = service.recover
      assert result, "Expected recovery to return true for running process"
    end

    # Verify running_job_id was updated (to a non-nil value)
    @session.reload
    assert_not_nil @session.running_job_id
  end

  test "recover skips and returns handled when the session is in a frozen category" do
    @session.update!(category: Category.create!(name: "frozen-recover", is_frozen: true))

    # A frozen category is a parked bucket: recover must short-circuit before any
    # process check or job enqueue, and report the session as handled (true).
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |_pid| flunk("process should not be checked for a frozen-category session") }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm, skip_pid_check: false)

    assert_no_enqueued_jobs do
      result = service.recover
      assert result, "Expected recover to return true (handled) for a frozen-category session"
    end

    # Status is left untouched — no transition to needs_input.
    assert_equal "running", @session.reload.status
  end

  test "recover with stopped process transitions to needs_input" do
    # Create a mock process manager that reports the process as stopped
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| false }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm, skip_pid_check: false)

    # Create a mock poller
    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    TranscriptPollerService.stub :new, mock_poller do
      result = service.recover
      assert_not result, "Expected recovery to return false for stopped process"
    end

    # Verify session was transitioned to needs_input
    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.running_job_id

    # Verify mock was called
    mock_poller.verify
  end

  test "recover with skip_pid_check true always enqueues monitoring job regardless of process state" do
    # With skip_pid_check: true (production default), the service never calls
    # process_manager.running? — it always assumes the process might be alive
    # in another container and enqueues a monitoring job to check.
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| raise "should not be called" }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm, skip_pid_check: true)

    assert_enqueued_with(job: AgentSessionJob) do
      result = service.recover
      assert result, "Expected recovery to return true with skip_pid_check"
    end

    @session.reload
    assert_equal "running", @session.status
    assert_not_nil @session.running_job_id
  end

  test "recover without process_pid transitions to needs_input" do
    # Remove process_pid from metadata
    @session.update!(metadata: {})

    service = SessionRecoveryService.new(@session, process_manager: @mock_process_manager)

    result = service.recover
    assert_not result, "Expected recovery to return false when no PID"

    # Verify session was transitioned to needs_input
    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.running_job_id
  end

  test "process_still_running? returns true for running process" do
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| true }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm)

    assert service.process_still_running?(12345)
  end

  test "process_still_running? returns false for stopped process" do
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| false }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm)

    assert_not service.process_still_running?(12345)
  end

  test "process_still_running? returns false for nil pid" do
    service = SessionRecoveryService.new(@session, process_manager: @mock_process_manager)

    assert_not service.process_still_running?(nil)
  end

  test "recover with running process creates appropriate logs" do
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| true }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm, skip_pid_check: false)

    # Enqueue the recovery job
    service.recover

    # Verify logs were created
    logs = @session.logs.order(created_at: :asc)
    assert logs.any? { |log| log.content.include?("is still running") }
    assert logs.any? { |log| log.content.include?("Recovery job enqueued") }
  end

  test "recover with running process enqueues job with correct arguments" do
    # Regression test for issue #337: ensure resume_monitoring is passed as
    # keyword argument, not as positional argument (which would make follow_up_prompt a Hash)
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| pid == 12345 }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm, skip_pid_check: false)

    service.recover

    # Get the enqueued job and verify its arguments
    enqueued_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    recovery_job = enqueued_jobs.find { |job| job["job_class"] == "AgentSessionJob" }

    assert_not_nil recovery_job, "Expected AgentSessionJob to be enqueued"

    # Job arguments should be: [session_id, nil, {resume_monitoring: true}]
    # The nil is critical - without it, the hash gets passed as follow_up_prompt
    job_args = recovery_job["arguments"]
    assert_equal @session.id, job_args[0], "First argument should be session_id"
    assert_nil job_args[1], "Second argument (follow_up_prompt) should be nil, not a Hash"
    # ActiveJob serializes keyword args with additional metadata, just check the key we care about
    assert_equal true, job_args[2]["resume_monitoring"], "resume_monitoring should be true in keyword args"
  end

  test "recover with stopped process creates appropriate logs" do
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| false }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm, skip_pid_check: false)

    # Create a mock poller
    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    TranscriptPollerService.stub :new, mock_poller do
      service.recover
    end

    # Verify logs were created
    logs = @session.logs.order(created_at: :asc)
    assert logs.any? { |log| log.content.include?("has stopped") }
    assert logs.any? { |log| log.content.include?("Performing final transcript poll") }

    mock_poller.verify
  end

  test "recover with log_buffer uses buffer instead of creating logs directly" do
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| false }

    # Create a mock log buffer
    mock_buffer = Object.new
    logged_messages = []
    mock_buffer.define_singleton_method(:add) do |content, level: "info"|
      logged_messages << { content: content, level: level }
    end

    service = SessionRecoveryService.new(
      @session,
      process_manager: mock_pm,
      log_buffer: mock_buffer,
      skip_pid_check: false
    )

    # Create a mock poller
    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    TranscriptPollerService.stub :new, mock_poller do
      service.recover
    end

    # Verify log buffer was used
    assert logged_messages.any? { |log| log[:content].include?("has stopped") }

    # The state machine creates 1 log entry for the pause transition.
    # The service's add_log calls use the buffer, but state machine callbacks
    # create logs directly. This is expected behavior.
    assert_equal 1, @session.logs.count
    assert @session.logs.first.content.include?("[State Machine]")

    mock_poller.verify
  end

  # Tests for issue #599: ensure enqueued messages are processed after recovery
  test "recover with stopped process drains enqueued message queue" do
    # Setup: session with enqueued messages and stopped process
    @session.update!(session_id: SecureRandom.uuid)
    @session.enqueued_messages.create!(content: "Pending message 1", position: 1)
    @session.enqueued_messages.create!(content: "Pending message 2", position: 2)

    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| false }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm, skip_pid_check: false)

    # Create a mock poller
    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    # Should enqueue a job to process the first enqueued message
    assert_enqueued_with(job: AgentSessionJob) do
      TranscriptPollerService.stub :new, mock_poller do
        result = service.recover
        assert_not result, "Expected recovery to return false for stopped process"
      end
    end

    @session.reload

    # Session should be running now (resumed to process message)
    assert_equal "running", @session.status

    # First message should be deleted (processed)
    assert_equal 1, @session.enqueued_messages.pending.count
    assert_equal "Pending message 2", @session.enqueued_messages.pending.first.content

    # Verify log indicates message was processed
    logs = @session.logs.order(created_at: :asc)
    assert logs.any? { |log| log.content.include?("Processing enqueued message") }

    mock_poller.verify
  end

  test "recover with stopped process and no enqueued messages stays in needs_input" do
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| false }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm, skip_pid_check: false)

    # Create a mock poller
    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    TranscriptPollerService.stub :new, mock_poller do
      result = service.recover
      assert_not result, "Expected recovery to return false for stopped process"
    end

    @session.reload

    # Session should remain in needs_input (no messages to process)
    assert_equal "needs_input", @session.status
    assert_nil @session.running_job_id

    mock_poller.verify
  end

  test "recover with stopped process clears leftover recovery_termination_initiated flag" do
    # Simulate a leftover flag from a previous recovery attempt that crashed
    # after setting the flag but before clearing it. The next cleanup cycle
    # should clear it via transition_to_needs_input.
    @session.update!(
      metadata: (@session.metadata || {}).merge("recovery_termination_initiated" => true)
    )

    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| false }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm, skip_pid_check: false)

    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    TranscriptPollerService.stub :new, mock_poller do
      service.recover
    end

    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.metadata["recovery_termination_initiated"],
      "Leftover recovery_termination_initiated flag should be cleared by transition_to_needs_input"

    mock_poller.verify
  end

  test "recover with stopped process and pending_sleep flag lands in needs_input not waiting" do
    # Regression test: long-running orchestrators set pending_sleep in metadata
    # whenever they call wake_me_up_later while running. If recovery pauses such a
    # session, the pause callback's execute_pending_sleep would bounce it
    # needs_input → waiting — a dead state with no wake trigger to ever resume it.
    # transition_to_needs_input must strip pending_sleep before pausing so recovery
    # deterministically lands in needs_input.
    @session.update!(
      metadata: (@session.metadata || {}).merge("pending_sleep" => true)
    )

    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| false }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm, skip_pid_check: false)

    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    TranscriptPollerService.stub :new, mock_poller do
      service.recover
    end

    @session.reload
    assert_equal "needs_input", @session.status,
      "Recovery pause must land in needs_input, not be bounced to waiting by pending_sleep"
    assert_nil @session.metadata["pending_sleep"],
      "pending_sleep should be stripped by transition_to_needs_input"
    assert_equal "recovery", @session.metadata["paused_by"]

    mock_poller.verify
  end

  # Tests for preventing duplicate monitoring jobs from being enqueued (job queue clog fix)
  test "pending_monitoring_job_exists? returns false when no pending jobs exist" do
    service = SessionRecoveryService.new(@session, process_manager: @mock_process_manager)

    # Ensure no pending jobs exist
    assert_not service.pending_monitoring_job_exists?
  end

  test "pending_monitoring_job_exists? returns true when pending monitoring job exists" do
    # Enqueue a monitoring job for this session
    AgentSessionJob.enqueue_for_monitoring(@session.id)

    service = SessionRecoveryService.new(@session, process_manager: @mock_process_manager)

    # Should detect the pending job
    assert service.pending_monitoring_job_exists?
  end

  test "pending_monitoring_job_exists? returns false for pending jobs with different session" do
    # Create another session
    other_session = Session.create!(
      prompt: "Other prompt",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/other-repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "process_pid" => 99999 }
    )

    # Enqueue a monitoring job for the OTHER session
    AgentSessionJob.enqueue_for_monitoring(other_session.id)

    service = SessionRecoveryService.new(@session, process_manager: @mock_process_manager)

    # Should NOT detect the other session's job
    assert_not service.pending_monitoring_job_exists?
  end

  test "pending_monitoring_job_exists? returns false for non-monitoring jobs" do
    # Enqueue a regular (non-monitoring) job for this session
    AgentSessionJob.enqueue_new_session(@session.id)

    service = SessionRecoveryService.new(@session, process_manager: @mock_process_manager)

    # Should NOT detect non-monitoring jobs
    assert_not service.pending_monitoring_job_exists?
  end

  test "recover skips when pending monitoring job already exists" do
    # Pre-enqueue a monitoring job for this session
    AgentSessionJob.enqueue_for_monitoring(@session.id)

    # Create a mock process manager that reports the process as running
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| true }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm)

    initial_job_count = GoodJob::Job.where(finished_at: nil, job_class: "AgentSessionJob").count

    result = service.recover

    # Should return true (session is being handled)
    assert result, "Expected recovery to return true when pending job exists"

    # No NEW job should be enqueued
    final_job_count = GoodJob::Job.where(finished_at: nil, job_class: "AgentSessionJob").count
    assert_equal initial_job_count, final_job_count, "No new job should be enqueued when pending job exists"

    # Verify a log was created about skipping
    logs = @session.logs.order(created_at: :asc)
    assert logs.any? { |log| log.content.include?("Skipping recovery") && log.content.include?("pending monitoring job") }
  end

  test "pending_monitoring_job_exists? returns false for zombie jobs that started but never finished" do
    # Simulate a zombie/stuck GoodJob: performed_at is set (job started executing)
    # but finished_at is nil (job never completed). This happens when a worker process
    # is hard-killed (SIGKILL, OOM kill, etc.) before GoodJob can update the job record.
    # These zombie jobs should NOT block recovery.
    GoodJob::Job.create!(
      active_job_id: SecureRandom.uuid,
      job_class: "AgentSessionJob",
      queue_name: "default",
      serialized_params: {
        "job_class" => "AgentSessionJob",
        "arguments" => [
          @session.id, nil,
          { "resume_monitoring" => true, "_aj_symbol_keys" => [ "resume_monitoring" ] }
        ]
      },
      performed_at: 10.minutes.ago,  # Started executing
      finished_at: nil                # Never completed (zombie)
    )

    service = SessionRecoveryService.new(@session, process_manager: @mock_process_manager)

    # Should NOT detect the zombie job as pending - it's stuck, not waiting to run
    assert_not service.pending_monitoring_job_exists?,
      "Zombie job (performed but not finished) should not block recovery"
  end

  test "recover proceeds despite zombie monitoring job and recovers session" do
    # Create a zombie monitoring job in GoodJob
    GoodJob::Job.create!(
      active_job_id: SecureRandom.uuid,
      job_class: "AgentSessionJob",
      queue_name: "default",
      serialized_params: {
        "job_class" => "AgentSessionJob",
        "arguments" => [
          @session.id, nil,
          { "resume_monitoring" => true, "_aj_symbol_keys" => [ "resume_monitoring" ] }
        ]
      },
      performed_at: 10.minutes.ago,
      finished_at: nil
    )

    # Process has stopped
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| false }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm, skip_pid_check: false)

    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    TranscriptPollerService.stub :new, mock_poller do
      result = service.recover
      assert_not result, "Expected recovery to proceed and return false for stopped process"
    end

    # Session should be recovered to needs_input
    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.running_job_id

    mock_poller.verify
  end

  test "recover proceeds when no pending monitoring job exists" do
    # Create a mock process manager that reports the process as running
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| true }

    service = SessionRecoveryService.new(@session, process_manager: mock_pm, skip_pid_check: false)

    # Should enqueue a new job
    assert_enqueued_with(job: AgentSessionJob) do
      result = service.recover
      assert result, "Expected recovery to return true for running process"
    end
  end

  # Tests for hung process termination (force_terminate_hung_process: true)
  test "recover with force_terminate_hung_process terminates and auto-restarts session" do
    # Give session the required metadata for auto-restart
    @session.update!(
      session_id: SecureRandom.uuid,
      metadata: @session.metadata.merge("working_directory" => Rails.root.to_s)
    )

    termination_called = false
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| !termination_called }
    mock_pm.define_singleton_method(:kill) do |signal, pid|
      termination_called = true
    end
    mock_pm.define_singleton_method(:wait) { |pid, flags| nil }

    service = SessionRecoveryService.new(
      @session,
      process_manager: mock_pm,
      force_terminate_hung_process: true
    )

    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    assert_enqueued_with(job: AgentSessionJob) do
      TranscriptPollerService.stub :new, mock_poller do
        result = service.recover
        assert result, "Expected recovery to return true when auto-restarting after hung process"
      end
    end

    # Verify session was auto-restarted (running, not needs_input)
    @session.reload
    assert_equal "running", @session.status

    # Verify termination was attempted
    assert termination_called, "Expected process termination to be called"

    # Verify auto-restart log
    logs = @session.logs.order(created_at: :asc)
    assert logs.any? { |log| log.content.include?("Auto-restarting session") }

    mock_poller.verify
  end

  test "recover with force_terminate_hung_process falls back to needs_input without session_id" do
    # Session without session_id cannot be auto-restarted
    @session.update!(session_id: nil)

    termination_called = false
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| !termination_called }
    mock_pm.define_singleton_method(:kill) do |signal, pid|
      termination_called = true
    end
    mock_pm.define_singleton_method(:wait) { |pid, flags| nil }

    service = SessionRecoveryService.new(
      @session,
      process_manager: mock_pm,
      force_terminate_hung_process: true
    )

    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    TranscriptPollerService.stub :new, mock_poller do
      service.recover
    end

    # Session stays at needs_input since it can't auto-restart
    @session.reload
    assert_equal "needs_input", @session.status

    # Verify warning log about missing session_id
    logs = @session.logs.order(created_at: :asc)
    assert logs.any? { |log| log.content.include?("Cannot auto-restart") && log.content.include?("no session_id") }

    mock_poller.verify
  end

  test "recover with force_terminate_hung_process falls back to needs_input without working_directory" do
    @session.update!(
      session_id: SecureRandom.uuid,
      metadata: @session.metadata.except("working_directory")
    )

    termination_called = false
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| !termination_called }
    mock_pm.define_singleton_method(:kill) do |signal, pid|
      termination_called = true
    end
    mock_pm.define_singleton_method(:wait) { |pid, flags| nil }

    service = SessionRecoveryService.new(
      @session,
      process_manager: mock_pm,
      force_terminate_hung_process: true
    )

    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    TranscriptPollerService.stub :new, mock_poller do
      service.recover
    end

    # Session stays at needs_input since it can't auto-restart
    @session.reload
    assert_equal "needs_input", @session.status

    # Verify warning log about missing working_directory
    logs = @session.logs.order(created_at: :asc)
    assert logs.any? { |log| log.content.include?("Cannot auto-restart") && log.content.include?("working directory") }

    mock_poller.verify
  end

  test "recover with force_terminate_hung_process falls back to needs_input when working_directory does not exist on disk" do
    @session.update!(
      session_id: SecureRandom.uuid,
      metadata: @session.metadata.merge("working_directory" => "/tmp/nonexistent-clone-dir-#{SecureRandom.hex(8)}")
    )

    termination_called = false
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| !termination_called }
    mock_pm.define_singleton_method(:kill) do |signal, pid|
      termination_called = true
    end
    mock_pm.define_singleton_method(:wait) { |pid, flags| nil }

    service = SessionRecoveryService.new(
      @session,
      process_manager: mock_pm,
      force_terminate_hung_process: true
    )

    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    TranscriptPollerService.stub :new, mock_poller do
      service.recover
    end

    @session.reload
    assert_equal "needs_input", @session.status

    logs = @session.logs.order(created_at: :asc)
    assert logs.any? { |log| log.content.include?("Cannot auto-restart") && log.content.include?("working directory") }

    mock_poller.verify
  end

  test "recover with force_terminate_hung_process falls back to needs_input when auto-restart raises" do
    @session.update!(
      session_id: SecureRandom.uuid,
      metadata: @session.metadata.merge("working_directory" => Rails.root.to_s)
    )

    termination_called = false
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| !termination_called }
    mock_pm.define_singleton_method(:kill) do |signal, pid|
      termination_called = true
    end
    mock_pm.define_singleton_method(:wait) { |pid, flags| nil }

    service = SessionRecoveryService.new(
      @session,
      process_manager: mock_pm,
      force_terminate_hung_process: true
    )

    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    # Stub enqueue_with_prompt to raise an error
    AgentSessionJob.stub :enqueue_with_prompt, ->(*_args) { raise "Simulated enqueue failure" } do
      TranscriptPollerService.stub :new, mock_poller do
        service.recover
      end
    end

    # Session should remain at needs_input (fallback from failed auto-restart)
    @session.reload
    assert_equal "needs_input", @session.status

    # Verify error log was created
    logs = @session.logs.order(created_at: :asc)
    assert logs.any? { |log| log.content.include?("Failed to auto-restart") && log.content.include?("Simulated enqueue failure") }

    mock_poller.verify
  end

  test "recover with force_terminate_hung_process creates appropriate logs" do
    # Give session required metadata for auto-restart
    @session.update!(
      session_id: SecureRandom.uuid,
      metadata: @session.metadata.merge("working_directory" => Rails.root.to_s)
    )

    # Process is running initially, then not running after termination
    termination_called = false
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| !termination_called }
    mock_pm.define_singleton_method(:kill) do |signal, pid|
      termination_called = true
    end
    mock_pm.define_singleton_method(:wait) { |pid, flags| nil }

    service = SessionRecoveryService.new(
      @session,
      process_manager: mock_pm,
      force_terminate_hung_process: true
    )

    # Create a mock poller
    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    TranscriptPollerService.stub :new, mock_poller do
      service.recover
    end

    # Verify logs were created about hung process
    logs = @session.logs.order(created_at: :asc)
    assert logs.any? { |log| log.content.include?("appears hung") }
    assert logs.any? { |log| log.content.include?("terminated") }
    assert logs.any? { |log| log.content.include?("Auto-restarting session") }

    mock_poller.verify
  end

  test "recover without force_terminate_hung_process enqueues monitoring job for running process" do
    # Create a mock process manager that reports the process as running
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| true }

    # Default behavior (force_terminate_hung_process: false)
    service = SessionRecoveryService.new(@session, process_manager: mock_pm, skip_pid_check: false)

    # Should enqueue a monitoring job, not terminate
    assert_enqueued_with(job: AgentSessionJob) do
      result = service.recover
      assert result, "Expected recovery to return true for running process without force"
    end
  end

  test "recover with force_terminate_hung_process sets recovery_termination_initiated flag before killing" do
    # Give session required metadata for auto-restart
    @session.update!(
      session_id: SecureRandom.uuid,
      metadata: @session.metadata.merge("working_directory" => Rails.root.to_s)
    )

    # Track the order of operations: flag should be set BEFORE kill is called
    operations = []
    session_id_for_mock = @session.id
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| true }
    mock_pm.define_singleton_method(:kill) do |signal, pid|
      # At the time kill is called, the flag should already be set in the DB
      session_check = Session.find(session_id_for_mock)
      operations << {
        action: :kill,
        flag_set: session_check.metadata&.dig("recovery_termination_initiated") == true
      }
    end
    mock_pm.define_singleton_method(:wait) { |pid, flags| nil }

    service = SessionRecoveryService.new(
      @session,
      process_manager: mock_pm,
      force_terminate_hung_process: true
    )

    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    TranscriptPollerService.stub :new, mock_poller do
      service.recover
    end

    # Verify kill was called and the flag was set before it happened
    assert operations.any? { |op| op[:action] == :kill },
      "Expected kill to be called"
    assert operations.all? { |op| op[:flag_set] },
      "Expected recovery_termination_initiated flag to be set before process kill"

    # After recovery completes, the flag should be cleared (auto-restart clears it)
    @session.reload
    assert_nil @session.metadata["recovery_termination_initiated"],
      "recovery_termination_initiated flag should be cleared after recovery"

    mock_poller.verify
  end

  test "recover with force_terminate_hung_process processes enqueued messages after termination" do
    # Setup: session with enqueued messages
    @session.update!(session_id: SecureRandom.uuid)
    @session.enqueued_messages.create!(content: "Pending after hung", position: 1)

    # Process is running initially, then not running after termination
    termination_called = false
    mock_pm = Object.new
    mock_pm.define_singleton_method(:running?) { |pid| !termination_called }
    mock_pm.define_singleton_method(:kill) do |signal, pid|
      termination_called = true
    end
    mock_pm.define_singleton_method(:wait) { |pid, flags| nil }

    service = SessionRecoveryService.new(
      @session,
      process_manager: mock_pm,
      force_terminate_hung_process: true
    )

    # Create a mock poller
    mock_poller = Minitest::Mock.new
    mock_poller.expect :poll_and_broadcast, nil

    # Should enqueue a job to process the enqueued message
    assert_enqueued_with(job: AgentSessionJob) do
      TranscriptPollerService.stub :new, mock_poller do
        service.recover
      end
    end

    @session.reload
    # Session should be running now (resumed to process message)
    assert_equal "running", @session.status

    # Pending message should be consumed
    assert_equal 0, @session.enqueued_messages.pending.count

    mock_poller.verify
  end
end
