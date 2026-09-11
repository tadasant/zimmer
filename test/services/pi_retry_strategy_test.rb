# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# PiRetryStrategy answers ProcessLifecycleManager's recovery questions from the
# error Pi recorded on the failed turn (PiTurnError). These tests pin down three
# things: that the retryable failures route to the backoff path, that the two
# conditions Pi has no recovery for are declined DELIBERATELY rather than by
# omission, and that the terminal-error backstop still reads the shape Pi writes.
#
# Every transcript here is a verbatim run of the real `pi 0.84.4` binary against
# a provider stub returning that failure — see PiSessionFixtures.
class PiRetryStrategyTest < ActiveSupport::TestCase
  WORKING_DIR = "/workspace/clone"

  setup do
    @file_system = MockFileSystemAdapter.new
    @session = Session.new(agent_runtime: "pi", session_id: SecureRandom.uuid)
    @strategy = PiRetryStrategy.new(
      cli_adapter: PiRuntimeAdapter.new,
      session: @session,
      file_system: @file_system,
      process_manager: MockProcessManager.new,
      rate_limit_tracker: nil,
      # The logger ProcessLifecycleManager passes. Its rescue blocks log with
      # keyword fields, which a plain Rails.logger does not take — so a test that
      # let the signature's default stand would raise from inside the rescue that
      # exists to stop exactly that.
      logger: StructuredLogger.new({ service: "PiRetryStrategyTest" })
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

  # === What routes to the backoff retry ===

  test "every transient provider failure is an API error worth retrying" do
    %i[server_500 bad_gateway_502 overloaded_503 rate_limit_429 insufficient_quota_429
       timeout_408 stream_terminated connection_error connection_error_garbage].each do |fixture|
      write_transcript(pi_session_for(fixture, @session.session_id))

      assert @strategy.api_error_for_retry?(working_dir: WORKING_DIR),
        "#{fixture} should route to the API-error backoff"
      assert_nil @strategy.unclassified_error_text(working_dir: WORKING_DIR),
        "#{fixture} is recognized, so it is not unclassified-alert material"
    end
  end

  test "a completed turn is not an API error" do
    write_transcript(pi_session_for(:completed, @session.session_id))

    assert_not @strategy.api_error_for_retry?(working_dir: WORKING_DIR)
  end

  # Pi retries a 5xx several times itself before giving up. A run where its own
  # retry succeeded ends on the answer, and must not be retried again by Zimmer.
  test "an error Pi retried past on its own is not an API error" do
    write_transcript(pi_session_for(:error_then_completed, @session.session_id))

    assert_not @strategy.api_error_for_retry?(working_dir: WORKING_DIR)
    assert_nil @strategy.terminal_api_error(working_dir: WORKING_DIR)
  end

  # The handled marker is what stops a respawn that died before writing anything
  # from being retried on the same dead turn.
  test "a turn a recovery already acted on is not offered for retry again" do
    write_transcript(pi_session_for(:server_500, @session.session_id))
    error = PiTurnError.terminal(pi_session_for(:server_500, @session.session_id))
    @session.metadata = { RecordedTurnError::HANDLED_KEY => error.id }

    assert_not @strategy.api_error_for_retry?(working_dir: WORKING_DIR)
    assert_not_nil @strategy.terminal_api_error(working_dir: WORKING_DIR),
      "the backstop ignores the marker: a turn a recovery gave up on is still dead"
  end

  test "no working directory and no transcript are both declined" do
    assert_not @strategy.api_error_for_retry?(working_dir: nil)
    assert_not @strategy.api_error_for_retry?(working_dir: WORKING_DIR)
  end

  # The rescue in #unhandled_error / #terminal_api_error is what keeps a
  # transcript read that blows up from breaking exit handling on an
  # already-failing session. Exercised, not assumed.
  test "a transcript read that raises is declined rather than propagated" do
    write_transcript(pi_session_for(:server_500, @session.session_id))
    @file_system.stubs(:read).raises(Errno::EIO)

    assert_not @strategy.api_error_for_retry?(working_dir: WORKING_DIR)
    assert_nil @strategy.terminal_api_error(working_dir: WORKING_DIR)
    assert_nil @strategy.unclassified_error_text(working_dir: WORKING_DIR)
  end

  # === What is declined by design ===
  #
  # Both of these detect fine — PiTurnError classifies them — and both answer
  # false because the service they would route to cannot act for Pi. See the
  # strategy's class docstring for the runs that establish it.

  test "a context-length failure is declined: Pi has no compaction to trigger" do
    write_transcript(pi_session_for(:context_length_400, @session.session_id))

    assert_equal :context_length_terminal,
      PiTurnError.terminal(pi_session_for(:context_length_400, @session.session_id)).kind
    assert_not @strategy.context_length_error?(stderr_log_path: "/tmp/pi_stderr.log")
    assert_not @strategy.api_error_for_retry?(working_dir: WORKING_DIR),
      "it must not be smuggled into the backoff path either — a resume only makes it longer"
  end

  test "the Pi adapter does not claim to compact on resume, which is why the above holds" do
    assert_not PiRuntimeAdapter.compacts_on_resume?
    assert_not PiRuntimeAdapter.new.compacts_on_resume?
  end

  test "an auth failure is declined: PiAuthProvider pools nothing to rotate to" do
    %i[unauthorized_401 forbidden_403 insufficient_credits_402].each do |fixture|
      write_transcript(pi_session_for(fixture, @session.session_id))

      assert_equal :auth_terminal, PiTurnError.terminal(pi_session_for(fixture, @session.session_id)).kind
      assert_not @strategy.auth_recovery_needed?(working_dir: WORKING_DIR)
      assert_not @strategy.api_error_for_retry?(working_dir: WORKING_DIR)
    end
  end

  # === The terminal provider error ===
  #
  # Pi exits 0 on a failed model call, so without this backstop
  # ProcessLifecycleManager took the success branch and parked the session as a
  # finished turn the model never answered.

  test "a turn that died on a provider error is reported with the provider's own wording" do
    write_transcript(pi_session_for(:unauthorized_401, @session.session_id))

    terminal = @strategy.terminal_api_error(working_dir: WORKING_DIR)

    assert_not_nil terminal, "a 401 that ended the turn must not look like a completed turn"
    assert_includes terminal.text, "401"
    assert_includes terminal.text, "Incorrect API key provided."
    assert terminal.line.present?, "the line is the key that stops one dead turn failing twice"
  end

  # A known failure with a deliberate disposition is failed and named without a
  # page. Only a wording nothing recognizes is news.
  test "a recognized failure is reported as recognized, so it does not page" do
    %i[unauthorized_401 context_length_400 server_500].each do |fixture|
      write_transcript(pi_session_for(fixture, @session.session_id))

      assert @strategy.terminal_api_error(working_dir: WORKING_DIR).recognized?, fixture.to_s
    end
  end

  test "an unrecognized failure is reported as unrecognized and offered to the alert" do
    write_transcript(pi_session_with_unknown_error(@session.session_id))

    assert_not @strategy.terminal_api_error(working_dir: WORKING_DIR).recognized?
    assert_includes @strategy.unclassified_error_text(working_dir: WORKING_DIR),
      PiSessionFixtures::UNKNOWN_WORDING
  end

  # A 4xx Zimmer read a status from is recognized even when it cannot name the
  # sub-reason, so it fails without paging. Production Pi runs on OpenRouter,
  # whose context refusal carries no code Zimmer knows — this is the case that
  # would otherwise be a standing alert.
  test "a rejection Zimmer cannot name more precisely is still not alert material" do
    %i[bad_request_400 openrouter_context_400].each do |fixture|
      write_transcript(pi_session_for(fixture, @session.session_id))

      assert @strategy.terminal_api_error(working_dir: WORKING_DIR).recognized?, fixture.to_s
      assert_nil @strategy.unclassified_error_text(working_dir: WORKING_DIR), fixture.to_s
      assert_not @strategy.api_error_for_retry?(working_dir: WORKING_DIR), fixture.to_s
    end
  end

  # Pi appends its own bookkeeping records around messages. A trailing one must
  # not make a terminal error look non-terminal.
  test "a trailing bookkeeping record does not mask a terminal error" do
    write_transcript(pi_session_for(:unauthorized_401, @session.session_id) +
      %({"type":"model_change","id":"mc2","parentId":"x","timestamp":"2026-09-11T20:34:17.000Z",) +
      %("provider":"sim","modelId":"sim-model"}\n))

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

  # The strategy's whole classification rests on the transcript source answering
  # this; a source that stopped would silently turn every retry back into a failure.
  test "the Pi transcript source is what makes any of this reachable" do
    assert PiTranscriptSource.new.records_turn_errors?
  end

  # Pi's classifiers now answer from the error Pi itself recorded, so an exit
  # none of them claims is genuinely unknown — which is what makes the
  # unclassified-failure alert informative rather than a standing page.
  test "claims to classify exits, so an unmatched exit is news" do
    assert @strategy.classifies_exits?
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
    @file_system.write(File.join(dir, "2026-09-11T20-34-16-693Z_#{@session.session_id}.jsonl"), contents)
  end
end
