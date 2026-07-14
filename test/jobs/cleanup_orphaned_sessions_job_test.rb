require "test_helper"

class CleanupOrphanedSessionsJobTest < ActiveJob::TestCase
  setup do
    # Use fixtures to avoid schema loading issues in CI
    @session = sessions(:running)
    @session.logs.destroy_all  # Clear any existing logs
    @session.update!(
      status: :running,
      running_job_id: SecureRandom.uuid,
      created_at: 1.minute.ago
    )
  end

  test "should move session to needs_input when process has stopped" do
    # Create a job in GoodJob with an error (simulating failed job)
    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      error: "Process was found dead and pruned"
    )

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify session was moved to needs_input (process is not running)
    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.running_job_id

    # Verify logs were created
    warning_log = orphan_detection_warning(@session)
    assert_not_nil warning_log
    assert_includes warning_log.content, "Detected orphaned session"

    verbose_log = @session.logs.find_by("content LIKE ?", "%Claude Code session appears to have died%")
    assert_not_nil verbose_log
    assert_includes verbose_log.content, "awaiting user instruction"
  end

  test "should move session to needs_input when job finished without updating status" do
    # Create a job in GoodJob that is finished
    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      finished_at: 1.hour.ago
    )

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify session was moved to needs_input
    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.running_job_id

    # Verify logs were created
    warning_log = orphan_detection_warning(@session)
    assert_not_nil warning_log
    assert_includes warning_log.content, "Job finished without updating session status"
  end

  test "should move session to needs_input when job does not exist" do
    # Don't create a job - the job_id doesn't exist
    @session.update!(running_job_id: "non-existent-job-id")

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify session was moved to needs_input
    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.running_job_id

    # Verify logs were created
    warning_log = orphan_detection_warning(@session)
    assert_not_nil warning_log
    assert_includes warning_log.content, "Job was orphaned or lost"
  end

  test "should move session to needs_input when job is orphaned (no executions)" do
    # Create a job in GoodJob created more than 5 minutes ago that isn't locked
    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      created_at: 10.minutes.ago,
      updated_at: 10.minutes.ago,
      locked_by_id: nil  # Not locked = not being processed
    )

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify session was moved to needs_input
    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.running_job_id
  end

  test "should not clean up session with active job" do
    # Create a job in GoodJob that is locked (actively running)
    process = GoodJob::Process.create!(
      state: { hostname: "localhost" }
    )

    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      locked_by_id: process.id,
      locked_at: Time.current
    )

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify session was NOT marked as failed
    @session.reload
    assert_equal "running", @session.status
    assert_equal @session.running_job_id, job.active_job_id
  ensure
    # Clean up
    process&.destroy
  end

  test "should not clean up session with scheduled job" do
    # Create a job in GoodJob that is scheduled for the future
    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      scheduled_at: 10.minutes.from_now
    )

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify session was NOT marked as failed
    @session.reload
    assert_equal "running", @session.status
    assert_equal @session.running_job_id, job.active_job_id
  end

  test "should not clean up session parked for a scheduled transient-clone-failure retry" do
    # Session is running with stale activity (which would normally trip the
    # last_timeline_entry_at orphan check), but it is parked awaiting a
    # future-scheduled clone retry. It must be left alone so it doesn't race a
    # duplicate job against the pending retry.
    @session.update!(
      last_timeline_entry_at: 30.minutes.ago,
      metadata: { "clone_retry_count" => 2 }
    )

    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      scheduled_at: 2.minutes.from_now
    )

    # Scope the assertion to THIS parked session rather than to the whole
    # AgentSessionJob class. Under the full parallel suite CleanupOrphanedSessionsJob
    # scans every session in the worker's DB and may legitimately enqueue a resume
    # job for some other orphan; a bare `assert_no_enqueued_jobs` (or even
    # `only: AgentSessionJob`) would count those and fail non-deterministically. The
    # intent here is only that @session — parked awaiting its future clone retry — is
    # not itself re-queued. Every AgentSessionJob enqueue path passes session_id as
    # its first positional argument, so we filter enqueued jobs by @session.id.
    CleanupOrphanedSessionsJob.perform_now

    resume_jobs_for_session = enqueued_jobs.select do |job|
      job[:job] == AgentSessionJob && Array(job[:args]).include?(@session.id)
    end
    assert_empty resume_jobs_for_session,
      "parked session #{@session.id} must not be re-queued while its clone retry is pending"

    @session.reload
    assert_equal "running", @session.status
    assert_equal job.active_job_id, @session.running_job_id
  end

  test "should still clean up stale session whose clone retry job has already finished" do
    # Once the retry job runs (finished, no longer future-scheduled) the parking
    # guard no longer applies, so a genuinely stale/hung session is recovered.
    @session.update!(
      last_timeline_entry_at: 30.minutes.ago,
      metadata: { "clone_retry_count" => 2 }
    )

    GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      scheduled_at: 20.minutes.ago,
      finished_at: 5.minutes.ago
    )

    CleanupOrphanedSessionsJob.perform_now

    @session.reload
    assert_equal "needs_input", @session.status
  end

  test "should not clean up sessions that are not running" do
    # Set session to completed status
    @session.update!(status: :needs_input)

    # Create a failed job
    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      error: "Test error"
    )

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify session status was not changed
    @session.reload
    assert_equal "needs_input", @session.status
  end

  test "should enqueue monitoring job when process pid exists but may not be running" do
    # Set up session with a process PID that doesn't exist locally.
    # With skip_pid_check: true (production default), the recovery service
    # does NOT check Process.kill(0, pid) because in multi-container deployments
    # the PID namespace differs. Instead it always enqueues a monitoring job.
    @session.update!(
      metadata: { "process_pid" => 99999, "clone_path" => "/tmp/test-clone" }
    )

    # Create a failed job
    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      error: "Test error"
    )

    # Run the cleanup job — should enqueue a monitoring job
    assert_enqueued_with(job: AgentSessionJob) do
      CleanupOrphanedSessionsJob.perform_now
    end

    # Session stays running; monitoring job will verify process status
    # in the correct PID namespace
    @session.reload
    assert_equal "running", @session.status
  end

  test "should attempt recovery when Claude CLI process is still running" do
    # Set up session with a running process (use current process as a substitute)
    @session.update!(
      metadata: {
        "process_pid" => Process.pid,
        "clone_path" => Rails.root.join("tmp", "test-clone").to_s
      }
    )

    # Store original job ID to verify it was replaced
    original_job_id = @session.running_job_id

    # Create a failed job
    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      error: "Process was found dead and pruned"
    )

    # Run the cleanup job
    assert_enqueued_with(job: AgentSessionJob) do
      CleanupOrphanedSessionsJob.perform_now
    end

    # Verify session is still running (will be monitored by recovery job)
    @session.reload
    assert_equal "running", @session.status

    # CRITICAL FIX: running_job_id should NEVER be nil for a running session
    # It should be replaced with the new recovery job's ID
    assert_not_nil @session.running_job_id, "running_job_id should never be nil for running session"
    assert_not_equal original_job_id, @session.running_job_id, "running_job_id should be updated to new job"

    # Verify logs indicate recovery attempt
    info_log = @session.logs.find_by("content LIKE ?", "%Attempting to recover%")
    assert_not_nil info_log

    # Verify recovery job was enqueued with ActiveJob ID logged
    recovery_log = @session.logs.find_by("content LIKE ?", "%Recovery job enqueued%")
    assert_not_nil recovery_log
    assert_includes recovery_log.content, "ActiveJob ID:"
  end

  test "running_job_id is never nil during recovery for running sessions" do
    # This test specifically verifies the atomic handoff fix
    @session.update!(
      metadata: {
        "process_pid" => Process.pid,
        "clone_path" => Rails.root.join("tmp", "test-clone").to_s
      }
    )

    original_job_id = @session.running_job_id

    # Create a failed job to trigger cleanup
    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      error: "Test error"
    )

    # Execute cleanup which should attempt recovery
    CleanupOrphanedSessionsJob.perform_now

    @session.reload

    # Verify running_job_id was replaced, not cleared
    assert_not_nil @session.running_job_id, "running_job_id should never be nil for running session"
    assert_not_equal original_job_id, @session.running_job_id, "running_job_id should be updated to new job"
    assert_equal "running", @session.status
  end

  test "recovery job is enqueued with resume_monitoring flag" do
    @session.update!(
      metadata: {
        "process_pid" => Process.pid,
        "clone_path" => Rails.root.join("tmp", "test-clone").to_s
      }
    )

    # Create a failed job
    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      error: "Test error"
    )

    # Verify the enqueued job has the correct parameters
    # Note: nil is required as second arg to ensure resume_monitoring is passed as keyword arg
    assert_enqueued_with(
      job: AgentSessionJob,
      args: [ @session.id, nil, { resume_monitoring: true } ]
    ) do
      CleanupOrphanedSessionsJob.perform_now
    end
  end

  test "should handle multiple orphaned sessions" do
    # Create second orphaned session using another fixture
    session2 = sessions(:waiting)
    session2.logs.destroy_all
    session2.update!(
      status: :running,
      running_job_id: SecureRandom.uuid,
      created_at: 1.minute.ago
    )

    # Create failed jobs for both sessions
    job1 = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      error: "Test error 1"
    )

    job2 = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: session2.running_job_id, arguments: [ session2.id ] }.to_json,
      active_job_id: session2.running_job_id,
      error: "Test error 2"
    )

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify both sessions were moved to needs_input
    @session.reload
    session2.reload

    assert_equal "needs_input", @session.status
    assert_equal "needs_input", session2.status
    assert_nil @session.running_job_id
    assert_nil session2.running_job_id
  end

  test "should detect and recover sessions with nil running_job_id" do
    # This is the key test for the bug fix - sessions with status:running but running_job_id:nil
    # should be detected as orphaned and recovered
    @session.update!(
      status: :running,
      running_job_id: nil  # This is the bug condition we're fixing
    )

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify session was detected as orphaned and moved to needs_input
    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.running_job_id

    # Verify logs were created
    warning_log = orphan_detection_warning(@session)
    assert_not_nil warning_log
    assert_includes warning_log.content, "Detected orphaned session"
    assert_includes warning_log.content, "Job was orphaned or lost"
  end

  test "should attempt recovery for sessions with nil running_job_id when process is running" do
    # Test recovery when session has nil running_job_id but process is still alive
    @session.update!(
      status: :running,
      running_job_id: nil,  # Bug condition
      metadata: {
        "process_pid" => Process.pid,  # Use current process as a stand-in
        "clone_path" => Rails.root.join("tmp", "test-clone").to_s
      }
    )

    # Run the cleanup job
    assert_enqueued_with(job: AgentSessionJob) do
      CleanupOrphanedSessionsJob.perform_now
    end

    # Verify session is still running and recovery job was assigned
    @session.reload
    assert_equal "running", @session.status
    assert_not_nil @session.running_job_id, "running_job_id should be set to recovery job ID"

    # Verify recovery logs were created
    info_log = @session.logs.find_by("content LIKE ?", "%Attempting to recover%")
    assert_not_nil info_log

    recovery_log = @session.logs.find_by("content LIKE ?", "%Recovery job enqueued%")
    assert_not_nil recovery_log
    assert_includes recovery_log.content, "ActiveJob ID:"
  end

  test "should detect and recover sessions with empty string running_job_id" do
    # Test that empty string is handled the same as nil (both covered by .blank?)
    @session.update!(
      status: :running,
      running_job_id: ""  # Empty string should also be detected as orphaned
    )

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify session was detected as orphaned and moved to needs_input
    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.running_job_id

    # Verify logs were created
    warning_log = orphan_detection_warning(@session)
    assert_not_nil warning_log
    assert_includes warning_log.content, "Detected orphaned session"
    assert_includes warning_log.content, "Job was orphaned or lost"
  end

  test "should detect stale lock from dead process after deploy" do
    # Simulate a deploy scenario: job has a lock from a process that no longer exists
    dead_process_id = SecureRandom.uuid

    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      created_at: 10.minutes.ago,
      updated_at: 10.minutes.ago,
      locked_by_id: dead_process_id,  # Lock from a dead process
      locked_at: 10.minutes.ago
    )

    # Verify no GoodJob::Process exists with this ID (simulates dead process)
    assert_not GoodJob::Process.exists?(id: dead_process_id)

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify session was detected as orphaned
    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.running_job_id

    # Verify logs mention stale lock
    warning_log = orphan_detection_warning(@session)
    assert_not_nil warning_log
    assert_includes warning_log.content, "stale lock from dead process"
  end

  test "should detect session with no activity for extended period" do
    # Create a valid process to hold the lock
    process = GoodJob::Process.create!(
      state: { hostname: "localhost" }
    )

    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      created_at: 1.hour.ago,
      locked_by_id: process.id,
      locked_at: 1.hour.ago
    )

    # Session has no activity for over 15 minutes
    @session.update!(last_timeline_entry_at: 20.minutes.ago)

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify session was detected as orphaned due to inactivity
    @session.reload
    assert_equal "needs_input", @session.status
    assert_nil @session.running_job_id

    # Verify logs mention no activity
    warning_log = orphan_detection_warning(@session)
    assert_not_nil warning_log
    assert_includes warning_log.content, "No activity for"
  ensure
    process&.destroy
  end

  test "should not clean up session with recent activity even if lock is old" do
    # Create a valid process
    process = GoodJob::Process.create!(
      state: { hostname: "localhost" }
    )

    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      created_at: 1.hour.ago,
      locked_by_id: process.id,
      locked_at: 1.hour.ago
    )

    # Session has recent activity (within 15 minutes)
    @session.update!(last_timeline_entry_at: 5.minutes.ago)

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify session was NOT cleaned up
    @session.reload
    assert_equal "running", @session.status
    assert_equal @session.running_job_id, job.active_job_id
  ensure
    process&.destroy
  end

  test "should auto-continue recovery-paused session with valid metadata" do
    # Simulate a session that was previously transitioned to needs_input by recovery
    # (e.g., by AgentSessionJob detecting a dead process, or by a previous cleanup run).
    # This is the race condition fix: CleanupOrphanedSessionsJob now picks up these
    # stranded sessions and auto-continues them.
    working_dir = Dir.mktmpdir
    @session.update!(
      status: :needs_input,
      running_job_id: nil,
      session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => working_dir,
        "working_directory" => working_dir,
        "paused_by" => "recovery"
      }
    )

    assert_enqueued_with(job: AgentSessionJob) do
      CleanupOrphanedSessionsJob.perform_now
    end

    @session.reload
    assert_equal "running", @session.status
    assert @session.logs.any? { |log| log.content.include?("automatically continued") }
  ensure
    FileUtils.rm_rf(working_dir) if working_dir
  end

  test "should deliver a queued user message instead of the recovery prompt" do
    # The leapfrog fix: when a recovery-paused session has a pending user
    # message, the cron must deliver THAT message rather than injecting
    # SYSTEM_RECOVERY (which would otherwise starve the user's input on every
    # recovery pass).
    working_dir = Dir.mktmpdir
    @session.update!(
      status: :needs_input,
      running_job_id: nil,
      session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => working_dir,
        "working_directory" => working_dir,
        "paused_by" => "recovery"
      }
    )
    @session.enqueued_messages.create!(content: "Please rebase on main", position: 1)

    assert_enqueued_with(job: AgentSessionJob, args: [ @session.id, "Please rebase on main" ]) do
      CleanupOrphanedSessionsJob.perform_now
    end

    @session.reload
    assert_equal "running", @session.status
    assert_nil @session.metadata["paused_by"]
    assert_equal 0, @session.enqueued_messages.pending.count
    assert @session.logs.any? { |log| log.content.include?("delivering queued user message") }
    refute @session.logs.any? { |log| log.content == "Session automatically continued after orphan cleanup" }
  ensure
    FileUtils.rm_rf(working_dir) if working_dir
  end

  test "should auto-continue session stranded in waiting with paused_by recovery" do
    # Defense-in-depth: a session bounced needs_input → waiting by
    # execute_pending_sleep at recovery-pause time (pending_sleep lingered in
    # metadata) has no wake trigger and would otherwise be permanently stranded.
    # The cleanup cron catches "waiting" + paused_by: "recovery" and resumes it.
    working_dir = Dir.mktmpdir
    @session.update!(
      status: :waiting,
      running_job_id: nil,
      session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => working_dir,
        "working_directory" => working_dir,
        "paused_by" => "recovery"
      }
    )

    assert_enqueued_with(job: AgentSessionJob) do
      CleanupOrphanedSessionsJob.perform_now
    end

    @session.reload
    assert_equal "running", @session.status
    assert @session.logs.any? { |log| log.content.include?("automatically continued") }
  ensure
    FileUtils.rm_rf(working_dir) if working_dir
  end

  test "should not auto-continue dormant waiting session without paused_by recovery" do
    # A legitimately-dormant wake_me_up_later session reaches waiting via
    # pending_sleep but never has paused_by: "recovery". It must be left alone.
    working_dir = Dir.mktmpdir
    @session.update!(
      status: :waiting,
      running_job_id: nil,
      session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => working_dir,
        "working_directory" => working_dir,
        "pending_sleep" => true
      }
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      CleanupOrphanedSessionsJob.perform_now
    end

    @session.reload
    assert_equal "waiting", @session.status
    refute @session.logs.any? { |log| log.content.include?("automatically continued") }
  ensure
    FileUtils.rm_rf(working_dir) if working_dir
  end

  test "should not auto-continue recovery-paused session without session_id" do
    working_dir = Dir.mktmpdir
    @session.update!(
      status: :needs_input,
      running_job_id: nil,
      session_id: nil,
      metadata: {
        "clone_path" => working_dir,
        "working_directory" => working_dir,
        "paused_by" => "recovery"
      }
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      CleanupOrphanedSessionsJob.perform_now
    end

    @session.reload
    assert_equal "needs_input", @session.status
    assert @session.logs.any? { |log| log.content.include?("auto-continue skipped") }
  ensure
    FileUtils.rm_rf(working_dir) if working_dir
  end

  test "should not auto-continue recovery-paused session with invalid working directory" do
    @session.update!(
      status: :needs_input,
      running_job_id: nil,
      session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => "/nonexistent/path",
        "working_directory" => "/nonexistent/path",
        "paused_by" => "recovery"
      }
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      CleanupOrphanedSessionsJob.perform_now
    end

    @session.reload
    assert_equal "needs_input", @session.status
    assert @session.logs.any? { |log| log.content.include?("working directory") }
  end

  test "should not auto-continue session paused by user" do
    working_dir = Dir.mktmpdir
    @session.update!(
      status: :needs_input,
      running_job_id: nil,
      session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => working_dir,
        "working_directory" => working_dir,
        "paused_by" => "user"
      }
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      CleanupOrphanedSessionsJob.perform_now
    end

    @session.reload
    assert_equal "needs_input", @session.status
    # Should NOT have any auto-continue logs
    refute @session.logs.any? { |log| log.content.include?("automatically continued") }
  ensure
    FileUtils.rm_rf(working_dir) if working_dir
  end

  test "should not treat running session as orphaned when pending follow-up prompt exists" do
    # When a follow-up is in-flight (controller called resume! and enqueued job,
    # but job hasn't started yet), the session may appear orphaned (running with
    # no active job). The pending_follow_up_prompt metadata signals a follow-up
    # is about to be processed, so cleanup should leave the session alone.
    @session.update!(
      status: :running,
      running_job_id: nil,
      metadata: {
        "clone_path" => "/tmp/test-clone",
        "working_directory" => "/tmp/test-clone",
        "pending_follow_up_prompt" => "Please continue working"
      }
    )

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify session was NOT cleaned up
    @session.reload
    assert_equal "running", @session.status
    # No orphan detection logs should be created
    refute @session.logs.any? { |log| log.content.include?("Detected orphaned session") }
  end

  test "should not falsely detect dead process across container PID namespaces" do
    # In multi-container deployments (e.g., Kamal rolling deploys), the cleanup job may
    # run in a different container than the one that spawned the Claude CLI process.
    # Each container has its own PID namespace, so Process.kill(0, pid) would return
    # ESRCH even though the process is alive in another container.
    #
    # The fix: when the monitoring job is healthy (locked by alive process, recent activity),
    # trust it to handle process lifecycle instead of doing a cross-container PID check.

    # Create a valid GoodJob process (simulating healthy worker in another container)
    goodjob_process = GoodJob::Process.create!(
      state: { hostname: "other-container-hostname" }
    )

    job = GoodJob::Job.create!(
      queue_name: "default",
      job_class: "AgentSessionJob",
      serialized_params: { job_id: @session.running_job_id, arguments: [ @session.id ] }.to_json,
      active_job_id: @session.running_job_id,
      created_at: 5.minutes.ago,
      locked_by_id: goodjob_process.id,
      locked_at: Time.current
    )

    # Session has recent activity but PID is not visible in this container's namespace
    @session.update!(
      last_timeline_entry_at: 5.minutes.ago,
      metadata: {
        "process_pid" => 99999,  # PID from another container - not visible here
        "clone_path" => "/tmp/test-clone"
      }
    )

    # Run the cleanup job
    CleanupOrphanedSessionsJob.perform_now

    # Verify session was NOT cleaned up - the healthy monitoring job handles process lifecycle
    @session.reload
    assert_equal "running", @session.status
    assert_equal job.active_job_id, @session.running_job_id
  ensure
    goodjob_process&.destroy
  end

  test "should recover session that failed due to GoodJob::InterruptError" do
    # Simulate a session that failed because the InterruptError rescue block
    # couldn't transition to needs_input (e.g., DB connection lost during shutdown)
    working_dir = Dir.mktmpdir
    @session.update!(
      status: :failed,
      running_job_id: nil,
      session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => working_dir,
        "working_directory" => working_dir,
        "failure_reason" => "exception",
        "exception_class" => "GoodJob::InterruptError",
        "exception_message" => "GoodJob shutdown"
      }
    )

    assert_enqueued_with(job: AgentSessionJob) do
      CleanupOrphanedSessionsJob.perform_now
    end

    @session.reload
    assert_equal "running", @session.status
    # InterruptError metadata should be cleaned up
    assert_nil @session.metadata["exception_class"]
    assert_nil @session.metadata["exception_message"]
    assert_nil @session.metadata["paused_by"]
    # Should have recovery logs
    assert @session.logs.any? { |log| log.content.include?("deploy interruption") }
    assert @session.logs.any? { |log| log.content.include?("automatically continued") }
  ensure
    FileUtils.rm_rf(working_dir) if working_dir
  end

  test "should not recover session that failed for non-InterruptError reasons" do
    working_dir = Dir.mktmpdir
    @session.update!(
      status: :failed,
      running_job_id: nil,
      session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => working_dir,
        "working_directory" => working_dir,
        "failure_reason" => "exception",
        "exception_class" => "StandardError",
        "exception_message" => "Something broke"
      }
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      CleanupOrphanedSessionsJob.perform_now
    end

    @session.reload
    assert_equal "failed", @session.status
    assert_equal "StandardError", @session.metadata["exception_class"]
  ensure
    FileUtils.rm_rf(working_dir) if working_dir
  end

  test "should skip recently created sessions to avoid race with AgentSessionJob" do
    # Simulate a brand-new session just created by ScheduleTriggerJob.
    # The session has no running_job_id yet (AgentSessionJob hasn't started).
    @session.update!(
      status: :running,
      running_job_id: nil,
      created_at: 5.seconds.ago
    )

    # Run the cleanup job — it should skip this session due to the grace period
    CleanupOrphanedSessionsJob.perform_now

    # Session should NOT be transitioned to needs_input
    @session.reload
    assert_equal "running", @session.status
  end

  test "should not skip sessions older than 30 seconds with no running job" do
    # Session is old enough — grace period expired
    @session.update!(
      status: :running,
      running_job_id: nil,
      created_at: 1.minute.ago
    )

    # Run the cleanup job — should detect as orphaned
    CleanupOrphanedSessionsJob.perform_now

    @session.reload
    assert_equal "needs_input", @session.status
  end

  private

  # Fetch the orphan-detection warning deterministically.
  #
  # A single CleanupOrphanedSessionsJob run can leave MORE THAN ONE warning log
  # on the same session: the orphan-detection warning ("Detected orphaned
  # session: ...") from recover_orphaned_session, plus a "Recovery auto-continue
  # skipped: ..." warning when continue_recovery_paused_sessions later picks up
  # the now recovery-paused session but can't auto-continue it (this fixture
  # session has no session_id / working_directory). Both are level "warning".
  #
  # `@session.logs.find_by(level: "warning")` issues `LIMIT 1` with NO `ORDER BY`
  # (the logs association has no default order and Log has no default_scope), so
  # which of the two warnings Postgres returns is non-deterministic — the source
  # of this suite's flakiness. Look the orphan-detection log up by its stable
  # content prefix instead so the assertion targets exactly one row.
  def orphan_detection_warning(session)
    session.logs.find_by("level = ? AND content LIKE ?", "warning", "Detected orphaned session%")
  end
end
