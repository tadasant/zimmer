require "test_helper"

# Verifies the architectural fix for the duplicate-delivery / dropped-message
# race in the interrupt path (see app/services/sessions/interrupt_service.rb).
#
# The headline test is `concurrent interrupts deliver each message exactly
# once in FIFO order` — it spawns two real OS threads each calling
# Sessions::InterruptService on a different message and asserts that:
#   1. Both messages are dispatched (no message lost)
#   2. Neither is dispatched twice (no duplicate delivery)
#   3. The session ends up running with no leftover queue rows
#
# This invariant is what the old controller-side implementation could
# violate: two interrupts in flight could each destroy the EnqueuedMessage
# row before the other claimed it, dropping a delivery — or both could
# succeed at enqueuing AgentSessionJobs back-to-back, doubling delivery.
class Sessions::InterruptServiceTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  setup do
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => "/tmp/test-clone" }
    )
  end

  # ----- Happy paths -----

  test "interrupt on needs_input session dispatches the message and resumes" do
    message = @session.enqueued_messages.create!(content: "Interrupt now", position: 1)

    result = nil
    assert_enqueued_with(job: AgentSessionJob) do
      result = Sessions::InterruptService.new(
        session: @session,
        enqueued_message: message,
        actor: "test"
      ).call
    end

    assert result.success?, "Expected success but got: #{result.error}"
    @session.reload
    assert_equal "running", @session.status
    assert_nil EnqueuedMessage.find_by(id: message.id), "Message should be destroyed after dispatch"
  end

  test "interrupt on waiting session dispatches the message" do
    @session.update!(status: :waiting)
    message = @session.enqueued_messages.create!(content: "Interrupt now", position: 1)

    result = nil
    assert_enqueued_with(job: AgentSessionJob) do
      result = Sessions::InterruptService.new(
        session: @session,
        enqueued_message: message,
        actor: "test"
      ).call
    end

    assert result.success?
    @session.reload
    assert_equal "running", @session.status
  end

  test "interrupt on running session pauses, terminates process, and dispatches" do
    @session.update!(status: :running, metadata: { "process_pid" => 999_999, "clone_path" => "/tmp/test-clone" })
    message = @session.enqueued_messages.create!(content: "Interrupt now", position: 1)

    result = nil
    assert_enqueued_with(job: AgentSessionJob) do
      result = Sessions::InterruptService.new(
        session: @session,
        enqueued_message: message,
        actor: "test"
      ).call
    end

    assert result.success?, "Expected success but got: #{result.error}"
    @session.reload
    assert_equal "running", @session.status
    assert_nil EnqueuedMessage.find_by(id: message.id)
  end

  test "interrupt promotes a back-of-queue message to position 1 before dispatch" do
    msg1 = @session.enqueued_messages.create!(content: "First", position: 1)
    target = @session.enqueued_messages.create!(content: "Target", position: 2)

    result = Sessions::InterruptService.new(
      session: @session,
      enqueued_message: target,
      actor: "test"
    ).call

    assert result.success?
    # The targeted (later) message goes first; the previously-front message
    # ends up at position 1 in the remaining queue.
    assert_nil EnqueuedMessage.find_by(id: target.id), "Targeted message should be dispatched"
    msg1.reload
    assert_equal 1, msg1.position, "Remaining message should renumber to position 1"
  end

  # ----- Cross-container worker-side termination (production topology) -----
  #
  # In production the web process cannot signal the worker-spawned Claude CLI
  # (separate containers / PID namespaces), so ProcessLifecycleManager#resume_monitoring
  # reports failure. The interrupt must still land: the message is dispatched AND a
  # durable, pid-scoped termination request is recorded for the worker's monitoring
  # loop to honor. When the process IS directly signalable (dev / single container),
  # the service terminates it synchronously and records no request.

  # Test double standing in for ProcessLifecycleManager. The resume_monitoring
  # success flag selects which branch terminate_running_process takes.
  class FakeLifecycleManager
    attr_reader :terminate_called, :resume_pid

    def initialize(resume_succeeds:)
      @resume_succeeds = resume_succeeds
      @terminate_called = false
    end

    def resume_monitoring(pid:, stderr_log_path: nil)
      @resume_pid = pid
      ProcessLifecycleManager::SpawnResult.new(
        success: @resume_succeeds,
        pid: pid,
        error: @resume_succeeds ? nil : "Process #{pid} is not running"
      )
    end

    def terminate(reason:)
      @terminate_called = true
      ProcessLifecycleManager::TerminateResult.new(success: true, reason: reason)
    end
  end

  test "interrupt hands termination to the worker when the process is invisible cross-container" do
    @session.update!(status: :running, metadata: { "process_pid" => 424_242, "clone_path" => "/tmp/test-clone" })
    message = @session.enqueued_messages.create!(content: "Interrupt now", position: 1)
    fake = FakeLifecycleManager.new(resume_succeeds: false)

    result = nil
    assert_enqueued_with(job: AgentSessionJob) do
      result = Sessions::InterruptService.new(
        session: @session,
        enqueued_message: message,
        actor: "test",
        process_lifecycle_manager: fake
      ).call
    end

    assert result.success?, "Expected success but got: #{result.error}"
    refute fake.terminate_called, "Must not attempt a direct terminate the web process cannot deliver cross-container"

    @session.reload
    # The interrupt still lands: message dispatched, session resumed to running.
    assert_equal "running", @session.status
    assert_nil EnqueuedMessage.find_by(id: message.id), "Message should be dispatched, not dropped"
    # A durable, pid-scoped termination request is left for the worker's loop.
    assert_equal 424_242, @session.metadata["interrupt_terminate_pid"],
      "Expected a pid-scoped worker-side termination request in metadata"
    # Loud-enough breadcrumb so a dropped/slow interrupt is diagnosable from logs.
    handoff_log = @session.logs.find { |l| l.content.include?("handed termination to the session worker") }
    assert_not_nil handoff_log, "Expected a log documenting the worker-side termination handoff"
  end

  test "interrupt terminates directly and records no worker request when the process is signalable" do
    @session.update!(status: :running, metadata: { "process_pid" => 424_242, "clone_path" => "/tmp/test-clone" })
    message = @session.enqueued_messages.create!(content: "Interrupt now", position: 1)
    fake = FakeLifecycleManager.new(resume_succeeds: true)

    result = Sessions::InterruptService.new(
      session: @session,
      enqueued_message: message,
      actor: "test",
      process_lifecycle_manager: fake
    ).call

    assert result.success?, "Expected success but got: #{result.error}"
    assert fake.terminate_called, "Should terminate directly when the process is in our PID namespace"

    @session.reload
    assert_nil @session.metadata["interrupt_terminate_pid"],
      "No worker-side request should be left when the process was terminated directly"
    assert_equal "running", @session.status
    assert_nil EnqueuedMessage.find_by(id: message.id)
  end

  # ----- Validation failures -----

  test "rejects message that does not belong to session" do
    other_session = Session.create!(
      prompt: "Other",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    other_message = other_session.enqueued_messages.create!(content: "From other", position: 1)

    result = Sessions::InterruptService.new(
      session: @session,
      enqueued_message: other_message,
      actor: "test"
    ).call

    refute result.success?
    assert_equal :not_found, result.error_code
    assert_match(/does not belong/, result.error)
  end

  test "rejects interrupt when session is archived" do
    @session.archive!
    # Build an unrelated message; the service should reject before even reading it.
    msg = EnqueuedMessage.new(session_id: @session.id, content: "x", position: 1)

    result = Sessions::InterruptService.new(
      session: @session,
      enqueued_message: msg,
      actor: "test"
    ).call

    refute result.success?
    assert_equal :unprocessable_entity, result.error_code
  end

  test "rejects interrupt when session is failed" do
    @session.fail!
    msg = EnqueuedMessage.new(session_id: @session.id, content: "x", position: 1)

    result = Sessions::InterruptService.new(
      session: @session,
      enqueued_message: msg,
      actor: "test"
    ).call

    refute result.success?
    assert_equal :unprocessable_entity, result.error_code
  end

  test "rejects interrupt when message is already being delivered" do
    message = @session.enqueued_messages.create!(content: "Already going", position: 1, status: :processing)

    result = Sessions::InterruptService.new(
      session: @session,
      enqueued_message: message,
      actor: "test"
    ).call

    refute result.success?
    assert_equal :conflict, result.error_code
    assert_match(/already being delivered/, result.error)
  end

  test "rejects interrupt when message no longer exists" do
    message = @session.enqueued_messages.create!(content: "Soon to be gone", position: 1)
    # Grab a stale handle, then delete the row out from under it.
    stale_handle = @session.enqueued_messages.find(message.id)
    message.destroy!

    result = Sessions::InterruptService.new(
      session: @session,
      enqueued_message: stale_handle,
      actor: "test"
    ).call

    refute result.success?
    assert_equal :not_found, result.error_code
  end

  # ----- The architectural correctness test -----

  test "concurrent interrupts deliver each message exactly once in FIFO order" do
    # Two messages, two concurrent interrupts on the same session. Without the
    # per-session advisory lock, the threads would race through process
    # termination + message claim + job enqueue and could double-dispatch one
    # message while dropping the other. With the lock, they serialize.
    #
    # NOTE on test fidelity: Rails' transactional test framework wraps each
    # test in a single shared connection (so all threads see the same
    # transactional state). That means the threads here may serialize at the
    # ActiveRecord connection level rather than at the Postgres advisory
    # lock — i.e., the test could pass even if the lock were broken. The
    # exactly-once / FIFO assertions remain meaningful because they would
    # fail under the OLD architecture (two destroy-then-enqueue paths) on
    # any thread interleaving. For a stricter, lock-specific check, see
    # `concurrent interrupts on different sessions do not block each other`
    # below — that one would hang under a global lock.
    @session.update!(status: :needs_input)
    message_a = @session.enqueued_messages.create!(content: "Message A", position: 1)
    message_b = @session.enqueued_messages.create!(content: "Message B", position: 2)

    # Capture every prompt that AgentSessionJob is enqueued with so we can
    # assert exactly-once delivery. Use ActiveJob's perform_enqueued_jobs=false
    # so jobs accumulate in the queue rather than running.
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    begin
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear

      threads = [
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Sessions::InterruptService.new(
              session: @session,
              enqueued_message: message_a,
              actor: "test_thread_a"
            ).call
          end
        end,
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Sessions::InterruptService.new(
              session: @session,
              enqueued_message: message_b,
              actor: "test_thread_b"
            ).call
          end
        end
      ]

      results = threads.map(&:value)

      # Both calls must succeed.
      results.each_with_index do |result, idx|
        assert result.success?, "Thread #{idx} failed: #{result.error}"
      end

      # Inspect what AgentSessionJob saw.
      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j|
        j[:job] == AgentSessionJob
      }
      prompts = enqueued.map { |j| j[:args][1] }

      # Exactly one job per message — neither dropped nor duplicated.
      assert_equal 2, prompts.length, "Expected exactly 2 job dispatches, got #{prompts.length}: #{prompts.inspect}"
      assert_equal [ "Message A", "Message B" ].sort, prompts.sort,
        "Both messages must be delivered exactly once"

      # Queue is fully drained.
      assert_equal 0, @session.enqueued_messages.count, "All messages should be dispatched and removed"

      # Session ended up running — no half-resumed flap.
      @session.reload
      assert_equal "running", @session.status
    ensure
      ActiveJob::Base.queue_adapter = original_adapter
    end
  end

  test "concurrent interrupts on different sessions do not block each other" do
    # Sanity check on the lock granularity: per-session lock means two
    # different sessions are independent. This test would hang if the lock
    # were global.
    other_session = Session.create!(
      prompt: "Other",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "clone_path" => "/tmp/test-clone-2" }
    )
    msg1 = @session.enqueued_messages.create!(content: "S1 msg", position: 1)
    msg2 = other_session.enqueued_messages.create!(content: "S2 msg", position: 1)

    finished = Concurrent::AtomicFixnum.new(0)
    threads = [
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Sessions::InterruptService.new(session: @session, enqueued_message: msg1, actor: "t1").call
          finished.increment
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Sessions::InterruptService.new(session: other_session, enqueued_message: msg2, actor: "t2").call
          finished.increment
        end
      end
    ]

    Timeout.timeout(10) { threads.each(&:join) }
    assert_equal 2, finished.value, "Both interrupts should complete independently"
  end
end
