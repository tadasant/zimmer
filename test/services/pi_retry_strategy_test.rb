# frozen_string_literal: true

require "test_helper"

# PiRetryStrategy answers one question with real evidence — did this turn die on
# a provider error — and declines the rest. These tests pin down both halves:
# that the terminal-error backstop reads the shape Pi actually writes, and that
# every remaining `false` is a deliberate, documented state rather than an
# accident.
class PiRetryStrategyTest < ActiveSupport::TestCase
  WORKING_DIR = "/workspace/clone"
  PI_SESSION_ID = "22222222-3333-4444-5555-666666666661"

  setup do
    @file_system = MockFileSystemAdapter.new
    @session = Session.new(agent_runtime: "pi", session_id: PI_SESSION_ID)
    @strategy = PiRetryStrategy.new(
      cli_adapter: PiRuntimeAdapter.new,
      session: @session,
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

  # === The terminal provider error ===
  #
  # The fixture is the verbatim transcript of a real pinned Pi 0.84.4 run whose
  # simulated provider returned 401 (only the header `cwd` rewritten). Pi exited
  # 0, so without this backstop ProcessLifecycleManager took the success branch
  # and parked the session as a finished turn the model never answered.

  test "a turn that died on a provider error is reported with the provider's own wording" do
    write_transcript(file_fixture("pi_session_provider_error.jsonl").read)

    terminal = @strategy.terminal_api_error(working_dir: WORKING_DIR)

    assert_not_nil terminal, "a 401 that ended the turn must not look like a completed turn"
    assert_includes terminal.text, "401"
    assert_includes terminal.text, "Incorrect API key provided."
    assert terminal.line.present?, "the line is the key that stops one dead turn failing twice"
  end

  # Nothing here classifies a provider error yet, so no wording is "recognized" —
  # which is what routes it to a loud failure without a page.
  test "the terminal error is reported as unrecognized" do
    write_transcript(file_fixture("pi_session_provider_error.jsonl").read)

    assert_not @strategy.terminal_api_error(working_dir: WORKING_DIR).recognized?
  end

  # An error the session recovered from on its own is not terminal, and failing
  # the session for it would be wrong.
  test "an error followed by more conversation is not terminal" do
    recovered = file_fixture("pi_session_provider_error.jsonl").read +
      %({"type":"message","id":"later","parentId":"x","timestamp":"2026-09-03T16:41:52.000Z",) +
      %("message":{"role":"assistant","content":[{"type":"text","text":"recovered"}],) +
      %("stopReason":"stop"}}\n)
    write_transcript(recovered)

    assert_nil @strategy.terminal_api_error(working_dir: WORKING_DIR)
  end

  # Pi appends its own bookkeeping records around messages. A trailing one must
  # not make a terminal error look non-terminal.
  test "a trailing bookkeeping record does not mask a terminal error" do
    trailing = file_fixture("pi_session_provider_error.jsonl").read +
      %({"type":"model_change","id":"mc2","parentId":"x","timestamp":"2026-09-03T16:41:52.000Z",) +
      %("provider":"sim","modelId":"sim-model"}\n)
    write_transcript(trailing)

    assert_not_nil @strategy.terminal_api_error(working_dir: WORKING_DIR)
  end

  test "a clean transcript reports no terminal error" do
    write_transcript(file_fixture("pi_session.jsonl").read)

    assert_nil @strategy.terminal_api_error(working_dir: WORKING_DIR)
  end

  test "a missing transcript or working directory is nil rather than an error" do
    assert_nil @strategy.terminal_api_error(working_dir: nil)
    assert_nil @strategy.terminal_api_error(working_dir: WORKING_DIR)
  end

  # === What is still deferred ===
  #
  # Each names a recovery path that is Claude-shaped today (see the class
  # docstring). The failure is surfaced by the backstop above rather than hidden.
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

  private

  # Write the transcript where PiTranscriptSource locates it: the per-clone
  # session directory, under the `<timestamp>_<session id>.jsonl` name Pi uses.
  def write_transcript(contents)
    dir = PiTranscriptSource.session_directory(working_directory: WORKING_DIR)
    @file_system.mkdir_p(dir)
    @file_system.write(File.join(dir, "2026-09-03T16-41-50-237Z_#{PI_SESSION_ID}.jsonl"), contents)
  end
end
