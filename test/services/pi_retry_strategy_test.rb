# frozen_string_literal: true

require "test_helper"

# PiRetryStrategy classifies almost nothing, and these tests pin that down as a
# deliberate, documented state rather than an accident — including the one
# predicate whose `false` is genuinely CORRECT rather than deferred.
class PiRetryStrategyTest < ActiveSupport::TestCase
  setup do
    @file_system = MockFileSystemAdapter.new
    @strategy = PiRetryStrategy.new(
      cli_adapter: PiRuntimeAdapter.new,
      session: Session.new(agent_runtime: "pi"),
      file_system: @file_system,
      process_manager: MockProcessManager.new,
      rate_limit_tracker: nil
    )
  end

  # Pi exits 0 on a completed turn and non-zero on a genuine failure — it has no
  # Claude-style "exit 1 means paused for input" convention. Returning true here
  # would report a real failure as a paused turn with an empty transcript.
  test "no exit code counts as a normal paused completion" do
    assert_not @strategy.normal_completion_exit?(nil)
    assert_not @strategy.normal_completion_exit?(0)
    assert_not @strategy.normal_completion_exit?(1)
  end

  # This one is CORRECT, not deferred: `pi --session-id <uuid>` creates the
  # session when no file carries that id rather than exiting non-zero, so the
  # Codex "no rollout found" condition cannot arise. A lost transcript is handled
  # by PiTranscriptSource#rotates_transcript_files? being false instead.
  test "a failed resume is not a condition Pi can produce" do
    @file_system.write("/tmp/pi_stderr.log", "Error: no rollout found for thread id abc")

    assert_not @strategy.failed_resume_recovery_needed?(stderr_log_path: "/tmp/pi_stderr.log")
  end

  # These three are deferred, not correct — the Pi signatures are not
  # characterized. Each surfaces as an ordinary non-zero exit that
  # ProcessLifecycleManager reports, so the failure is surfaced rather than
  # hidden. Recorded in limitations.md.
  test "the unclassified predicates all defer to generic failure handling" do
    assert_not @strategy.context_length_error?(stderr_log_path: "/tmp/pi_stderr.log")
    assert_not @strategy.api_error_for_retry?(working_dir: "/tmp")
    assert_not @strategy.auth_recovery_needed?(working_dir: "/tmp")
    assert_nil @strategy.unclassified_error_text(working_dir: "/tmp")
  end

  # An ordinary Pi failure is always an exit no classifier matched, so alerting
  # on that would turn the expected shape of a Pi failure into a standing page.
  test "does not claim to classify exits, so it raises no unclassified-exit alert" do
    assert_not @strategy.classifies_exits?
  end

  # The five predicates ProcessLifecycleManager depends on. Implementing fewer
  # surfaces as a production NoMethodError on an already-failing session.
  test "implements every predicate the retry contract requires" do
    RuntimeCliAdapterContractAssertions::RETRY_STRATEGY_PREDICATES.each do |predicate|
      assert_respond_to @strategy, predicate
    end
  end

  test "the Pi adapter builds this strategy" do
    strategy = PiRuntimeAdapter.new.retry_strategy(
      session: Session.new(agent_runtime: "pi"),
      file_system: @file_system,
      process_manager: MockProcessManager.new,
      rate_limit_tracker: nil
    )

    assert_instance_of PiRetryStrategy, strategy
  end
end
