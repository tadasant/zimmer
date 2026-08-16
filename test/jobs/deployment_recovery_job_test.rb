require "test_helper"
require "minitest/mock"

class DeploymentRecoveryJobTest < ActiveJob::TestCase
  setup do
    @working_dir = Dir.mktmpdir
  end

  teardown do
    FileUtils.rm_rf(@working_dir) if @working_dir
  end

  test "recovers session in needs_input with paused_by recovery" do
    session = create_recoverable_session(status: :needs_input, paused_by: "recovery")

    assert_enqueued_with(job: AgentSessionJob) do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    assert_equal "running", session.status
    assert_nil session.metadata["paused_by"]
    assert session.logs.any? { |log| log.content.include?("automatically continued") }
  end

  test "recovers session stranded in waiting with paused_by recovery" do
    # Defense-in-depth: a session bounced needs_input → waiting by
    # execute_pending_sleep at recovery-pause time (pending_sleep lingered in
    # metadata) has no wake trigger and is otherwise permanently stranded.
    session = create_recoverable_session(status: :waiting, paused_by: "recovery")

    assert_enqueued_with(job: AgentSessionJob) do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    assert_equal "running", session.status
    assert_nil session.metadata["paused_by"]
    assert session.logs.any? { |log| log.content.include?("automatically continued") }
  end

  test "does not recover dormant waiting session without paused_by recovery" do
    # A legitimately-dormant wake_me_up_later session reaches waiting via
    # pending_sleep but never has paused_by: "recovery". It must be left alone.
    session = create_recoverable_session(status: :waiting, paused_by: nil)
    session.update!(metadata: session.metadata.merge("pending_sleep" => true))

    assert_no_enqueued_jobs only: AgentSessionJob do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    assert_equal "waiting", session.status
  end

  test "does not recover session in needs_input with paused_by user" do
    session = create_recoverable_session(status: :needs_input, paused_by: "user")

    assert_no_enqueued_jobs only: AgentSessionJob do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    assert_equal "needs_input", session.status
    assert_equal "user", session.metadata["paused_by"]
  end

  test "does not recover session in needs_input without paused_by" do
    session = create_recoverable_session(status: :needs_input, paused_by: nil)

    assert_no_enqueued_jobs only: AgentSessionJob do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    assert_equal "needs_input", session.status
  end

  test "recovers running session with no running_job_id" do
    session = create_recoverable_session(status: :running, paused_by: nil)
    session.update!(running_job_id: nil)

    # With skip_pid_check: true (production default), the recovery service
    # always attempts to re-monitor via AgentSessionJob rather than checking
    # the PID locally (which would fail across container PID namespaces).
    assert_enqueued_with(job: AgentSessionJob) do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    assert_equal "running", session.status
    # Recovery enqueues a monitoring job to reconnect to the process
    assert session.logs.any? { |log| log.content.include?("Recovery job enqueued") }
  end

  test "recovers running session whose job is locked by a capsule that did not survive the deploy" do
    # The case this job is named for. The replaced container's good_job_processes row is
    # still in the table, so the job still *looks* locked; only a liveness check sees that
    # nobody is executing it.
    session = create_recoverable_session(status: :running, paused_by: nil)
    session.update!(running_job_id: SecureRandom.uuid)
    zombie = GoodJob::Process.create!(state: { hostname: "replaced-container" })
    zombie.update_column(:updated_at, (GoodJob::Process::EXPIRED_INTERVAL.to_i + 60).seconds.ago)

    GoodJob::Job.create!(
      queue_name: "agents",
      job_class: "AgentSessionJob",
      active_job_id: session.running_job_id,
      serialized_params: { arguments: [ session.id ] }.to_json,
      created_at: 1.minute.ago,
      locked_by_id: zombie.id,
      locked_at: 1.minute.ago,
      performed_at: 1.minute.ago
    )

    assert_enqueued_with(job: AgentSessionJob) do
      DeploymentRecoveryJob.perform_now
    end
  ensure
    zombie&.destroy
  end

  test "recovers running session whose job started and then lost its lock" do
    # The likelier post-deploy shape, and the one the old check could not see at all.
    # GoodJob::Notifier::ProcessHeartbeat#register_process runs GoodJob::Process.cleanup
    # BEFORE registering the new capsule, and cleanup nulls locked_by_id on the dead
    # capsule's jobs — so by the time this cron looks, the row is usually unlocked with
    # performed_at set rather than still pointing at a dead process.
    session = create_recoverable_session(status: :running, paused_by: nil)
    session.update!(running_job_id: SecureRandom.uuid)

    GoodJob::Job.create!(
      queue_name: "agents",
      job_class: "AgentSessionJob",
      active_job_id: session.running_job_id,
      serialized_params: { arguments: [ session.id ] }.to_json,
      created_at: 1.minute.ago,
      performed_at: 1.minute.ago,
      locked_by_id: nil
    )

    assert_enqueued_with(job: AgentSessionJob) do
      DeploymentRecoveryJob.perform_now
    end
  end

  test "does not recover a running session whose job is merely queued behind a slow deploy" do
    # A queue backlog is not a death. Recovering here would run a second agent against the
    # same clone once the queued job is finally picked up. Held just inside
    # ABANDONED_QUEUED_JOB_AGE so this pins the new boundary rather than passing trivially.
    session = create_recoverable_session(status: :running, paused_by: nil)
    session.update!(running_job_id: SecureRandom.uuid)
    queued_since = JobLiveness::ABANDONED_QUEUED_JOB_AGE.ago + 1.minute

    GoodJob::Job.create!(
      queue_name: "agents",
      job_class: "AgentSessionJob",
      active_job_id: session.running_job_id,
      serialized_params: { arguments: [ session.id ] }.to_json,
      created_at: queued_since,
      scheduled_at: queued_since
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      DeploymentRecoveryJob.perform_now
    end
  end

  test "recovers a running session whose job sat unclaimed past the backstop horizon" do
    session = create_recoverable_session(status: :running, paused_by: nil)
    session.update!(running_job_id: SecureRandom.uuid)
    queued_since = JobLiveness::ABANDONED_QUEUED_JOB_AGE.ago - 1.minute

    GoodJob::Job.create!(
      queue_name: "agents",
      job_class: "AgentSessionJob",
      active_job_id: session.running_job_id,
      serialized_params: { arguments: [ session.id ] }.to_json,
      created_at: queued_since,
      scheduled_at: queued_since
    )

    assert_enqueued_with(job: AgentSessionJob) do
      DeploymentRecoveryJob.perform_now
    end
  end

  test "skips session without session_id" do
    session = create_recoverable_session(status: :needs_input, paused_by: "recovery")
    session.update!(session_id: nil)

    assert_no_enqueued_jobs only: AgentSessionJob do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    assert_equal "needs_input", session.status
    assert session.logs.any? { |log| log.content.include?("auto-continue skipped") }
  end

  test "skips session without valid working directory" do
    session = create_recoverable_session(status: :needs_input, paused_by: "recovery")
    session.update!(metadata: session.metadata.merge("working_directory" => "/nonexistent/path"))

    assert_no_enqueued_jobs only: AgentSessionJob do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    assert_equal "needs_input", session.status
    assert session.logs.any? { |log| log.content.include?("working directory") }
  end

  test "clears stale metadata when continuing session" do
    session = create_recoverable_session(status: :needs_input, paused_by: "recovery")
    session.update!(
      metadata: session.metadata.merge(
        "sigterm_retry_count" => 2,
        "sigterm_retry_timestamps" => [ Time.current.to_s ],
        "last_sigterm_at" => Time.current.to_s,
        "failure_reason" => "Previous failure",
        "mcp_failed_servers" => [ "server1" ]
      )
    )

    DeploymentRecoveryJob.perform_now

    session.reload
    assert_nil session.metadata["sigterm_retry_count"]
    assert_nil session.metadata["sigterm_retry_timestamps"]
    assert_nil session.metadata["last_sigterm_at"]
    assert_nil session.metadata["failure_reason"]
    assert_nil session.metadata["mcp_failed_servers"]
    assert_nil session.metadata["paused_by"]
  end

  test "handles multiple sessions" do
    session1 = create_recoverable_session(status: :needs_input, paused_by: "recovery")
    session2 = create_recoverable_session(status: :needs_input, paused_by: "recovery")
    session3 = create_recoverable_session(status: :needs_input, paused_by: "user")

    assert_enqueued_jobs 2, only: AgentSessionJob do
      DeploymentRecoveryJob.perform_now
    end

    session1.reload
    session2.reload
    session3.reload

    assert_equal "running", session1.status
    assert_equal "running", session2.status
    assert_equal "needs_input", session3.status
  end

  test "does nothing when no sessions need recovery" do
    # Create a session that doesn't need recovery
    create_recoverable_session(status: :needs_input, paused_by: "user")

    assert_no_enqueued_jobs only: AgentSessionJob do
      DeploymentRecoveryJob.perform_now
    end
  end

  test "recovers session that failed due to GoodJob::InterruptError" do
    # Simulate a session that was caught by the general rescue block instead of
    # the InterruptError-specific one (e.g., DB connection lost during shutdown)
    session = create_recoverable_session(status: :failed, paused_by: nil)
    session.update!(
      metadata: session.metadata.merge(
        "failure_reason" => "exception",
        "exception_class" => "GoodJob::InterruptError",
        "exception_message" => "GoodJob shutdown"
      )
    )

    assert_enqueued_with(job: AgentSessionJob) do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    assert_equal "running", session.status
    # InterruptError metadata should be cleaned up
    assert_nil session.metadata["exception_class"]
    assert_nil session.metadata["exception_message"]
    assert_nil session.metadata["paused_by"]
    # Should have recovery log
    assert session.logs.any? { |log| log.content.include?("deploy interruption") }
    assert session.logs.any? { |log| log.content.include?("automatically continued") }
  end

  test "does not recover session that failed for non-InterruptError reasons" do
    session = create_recoverable_session(status: :failed, paused_by: nil)
    session.update!(
      metadata: session.metadata.merge(
        "failure_reason" => "exception",
        "exception_class" => "StandardError",
        "exception_message" => "Something went wrong"
      )
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    assert_equal "failed", session.status
  end

  test "recovers mix of needs_input recovery and InterruptError failed sessions" do
    session1 = create_recoverable_session(status: :needs_input, paused_by: "recovery")
    session2 = create_recoverable_session(status: :failed, paused_by: nil)
    session2.update!(
      metadata: session2.metadata.merge(
        "exception_class" => "GoodJob::InterruptError"
      )
    )
    session3 = create_recoverable_session(status: :needs_input, paused_by: "user")

    assert_enqueued_jobs 2, only: AgentSessionJob do
      DeploymentRecoveryJob.perform_now
    end

    session1.reload
    session2.reload
    session3.reload

    assert_equal "running", session1.status
    assert_equal "running", session2.status
    assert_equal "needs_input", session3.status
  end

  test "delivers queued user message instead of recovery prompt when one is pending" do
    session = create_recoverable_session(status: :needs_input, paused_by: "recovery")
    session.enqueued_messages.create!(content: "Please rebase on main", position: 1)

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, "Please rebase on main" ]) do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    assert_equal "running", session.status
    assert_nil session.metadata["paused_by"]
    # The user's queued message was consumed, not leapfrogged.
    assert_equal 0, session.enqueued_messages.pending.count
    assert session.logs.any? { |log| log.content.include?("delivering queued user message") }
    # The automated recovery prompt was NOT sent.
    refute session.logs.any? { |log| log.content == "Session automatically continued after deployment recovery" }
  end

  test "delivers queued user message for waiting session paused by recovery" do
    session = create_recoverable_session(status: :waiting, paused_by: "recovery")
    session.enqueued_messages.create!(content: "Follow-up while waiting", position: 1)

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, "Follow-up while waiting" ]) do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    assert_equal "running", session.status
    assert_nil session.metadata["paused_by"]
    assert_equal 0, session.enqueued_messages.pending.count
  end

  test "delivers only the first queued message, leaving the rest in the queue" do
    session = create_recoverable_session(status: :needs_input, paused_by: "recovery")
    session.enqueued_messages.create!(content: "First message", position: 1)
    session.enqueued_messages.create!(content: "Second message", position: 2)

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, "First message" ]) do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    # The second message remains queued (renumbered to position 1) for the next turn.
    remaining = session.enqueued_messages.pending.ordered
    assert_equal 1, remaining.count
    assert_equal "Second message", remaining.first.content
  end

  test "sends automated recovery prompt when no message is queued" do
    session = create_recoverable_session(status: :needs_input, paused_by: "recovery")

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    assert_equal "running", session.status
    assert session.logs.any? { |log| log.content.include?("automatically continued") }
  end

  test "failed InterruptError session with a queued message falls through to recovery prompt, leaving the message queued" do
    # process_next_message refuses to resume a failed session, so the queued
    # message cannot be delivered on this pass. The session must still recover
    # via SYSTEM_RECOVERY, and the user's message must remain queued (not lost)
    # so it drains at the next clean turn boundary.
    session = create_recoverable_session(status: :failed, paused_by: nil)
    session.update!(metadata: session.metadata.merge("exception_class" => "GoodJob::InterruptError"))
    session.enqueued_messages.create!(content: "Held for next turn", position: 1)

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      DeploymentRecoveryJob.perform_now
    end

    session.reload
    assert_equal "running", session.status
    # The message survived the fall-through.
    assert_equal 1, session.enqueued_messages.pending.count
    assert_equal "Held for next turn", session.enqueued_messages.pending.ordered.first.content
    # Recovery markers were cleared atomically by the recovery prompt path.
    assert_nil session.metadata["paused_by"]
    assert_nil session.metadata["exception_class"]
  end

  # The stall this whole path exists to prevent, driven end to end through the
  # real recovery call site rather than through the state machine directly.
  #
  # Production shape (orchestrator sessions 4388, 4855, 4885): the session was
  # running when it armed watchers on its children plus a wake_me_up_later
  # backstop, so Trigger's auto-sleep set pending_sleep instead of sleeping it.
  # The worker then died mid-turn. SessionRecoveryService#transition_to_needs_input
  # strips pending_sleep and marks paused_by: "recovery", and the auto-continue
  # below resumes the session — which used to consume every pending wake on the
  # way through. The session finished its recovery turn in needs_input with
  # nothing armed and no sleep intent, and never woke again.
  test "auto-continue preserves the wake set and puts the session back to sleep" do
    session = create_recoverable_session(status: :running, paused_by: nil)
    conditions = arm_wake_set(session)

    # What SessionRecoveryService#transition_to_needs_input does to a running orphan.
    session.reload.update!(
      metadata: session.metadata.except("pending_sleep").merge("paused_by" => "recovery")
    )
    session.pause!
    assert session.reload.needs_input?, "precondition: recovery lands the orphan in needs_input"

    DeploymentRecoveryJob.perform_now

    session.reload
    assert_equal "running", session.status
    assert_equal true, session.metadata["pending_sleep"],
      "a recovered session holding a scheduled backstop must be told to sleep again after its turn"
    conditions.each do |condition|
      assert_nil condition.reload.last_triggered_at,
        "recovery must not consume wake condition #{condition.id}"
    end

    # The recovery turn completes.
    session.pause!

    assert session.reload.waiting?,
      "the session must return to waiting with its wake set intact, not sit in needs_input"
    assert_nil session.metadata["pending_sleep"]
    conditions.each do |condition|
      assert_nil condition.reload.last_triggered_at,
        "wake condition #{condition.id} must still be armed once the session is asleep again"
    end
  end

  # The other half of the contract: recovery preserves, a human does not. A
  # session auto-continued by recovery and then genuinely resumed by someone must
  # still have its now-moot wake-ups consumed.
  test "a deliberate resume after an auto-continue still consumes the wake set" do
    session = create_recoverable_session(status: :needs_input, paused_by: "recovery")

    DeploymentRecoveryJob.perform_now
    assert_equal "running", session.reload.status

    session.pause!
    conditions = arm_wake_set(session)

    session.reload.resume!

    conditions.each do |condition|
      assert_not_nil condition.reload.last_triggered_at,
        "a deliberate resume must still consume wake condition #{condition.id}"
    end
  end

  private

  # The wake set an orchestrator actually registers: a watcher on a child plus a
  # wake_me_up_later deadline backstop. Creating these runs Trigger's auto-sleep
  # callback, which is what sets pending_sleep on a running session.
  def arm_wake_set(session)
    watched = create_recoverable_session(status: :running, paused_by: nil)

    [
      { condition_type: "ao_event",
        configuration: { "event_name" => "session_archived", "watched_session_id" => watched.id } },
      { condition_type: "schedule",
        configuration: { "scheduled_at" => 30.minutes.from_now.iso8601, "timezone" => "UTC" } }
    ].map do |condition|
      Trigger.create!(
        name: "Wake ##{session.id}",
        status: "enabled",
        agent_root_name: "zimmer",
        prompt_template: "Wake",
        reuse_session: true,
        last_session_id: session.id,
        trigger_conditions_attributes: [ condition ]
      ).trigger_conditions.first
    end
  end

  def create_recoverable_session(status:, paused_by:)
    metadata = {
      "process_pid" => 12345,
      "clone_path" => @working_dir,
      "working_directory" => @working_dir
    }
    metadata["paused_by"] = paused_by if paused_by

    Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: status,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      metadata: metadata
    )
  end
end
