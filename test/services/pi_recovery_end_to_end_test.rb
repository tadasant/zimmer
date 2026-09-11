# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# A Pi session that hits each provider failure, driven through the same entry
# point production uses — ProcessLifecycleManager#handle_exit, with Pi's real
# exit code and the session JSONL the real `pi 0.84.4` wrote for that failure
# (PiSessionFixtures).
#
# **Pi exits 0 on a failed model call**, so every test here feeds exit 0. That is
# the whole difficulty of the Pi seam and the reason these run end to end: the
# classification has to happen on the door marked "the turn completed". Before
# #856 every one of these ended the same way — "Process exited successfully" and
# a park in `needs_input`, claiming a turn finished that the model never answered.
#
# What is real here: the retry strategy, the recovery services, the terminal-error
# backstop, and the ladder ProcessLifecycleManager#diagnose_completed_turn walks.
# What is not: the process (MockProcessManager), the CLI (MockPiRuntimeAdapter
# records the resume it was asked for), and wall-clock waits.
class PiRecoveryEndToEndTest < ActiveJob::TestCase
  CLONE = "/tmp/zimmer-pi-fixture"

  setup do
    @session = Session.create!(
      prompt: "Pi test prompt",
      agent_runtime: "pi",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => CLONE, "working_directory" => CLONE },
      transcript: { "type" => "user", "message" => { "content" => "Pi test prompt" } }.to_json
    )

    @file_system = MockFileSystemAdapter.new
    @file_system.mkdir_p(CLONE)
    @process_manager = MockProcessManager.new
    @adapter = MockPiRuntimeAdapter.new
    @rate_limit_tracker = GlobalRateLimitTracker.new
    @log_buffer = LogBuffer.new(@session)

    # No wall clock: the status confirmations, backoffs and the respawn's
    # five-second liveness bar are all waits, not behaviour.
    [ ProcessLifecycleManager, ApiErrorRetryService ].each { |klass| klass.any_instance.stubs(:sleep) }
    ApiErrorRetryService.any_instance.stubs(:verify_process_running).returns(true)
  end

  def manager
    @manager ||= ProcessLifecycleManager.new(
      session: @session,
      cli_adapter: @adapter,
      process_manager: @process_manager,
      log_buffer: @log_buffer,
      file_system: @file_system,
      rate_limit_tracker: @rate_limit_tracker
    )
  end

  # Spawn, let the real transcript for `fixture` land, and exit 0 the way Pi does
  # whether the model answered or not.
  def pi_turn_ends_with(fixture, exit_code: 0)
    manager.spawn(prompt: "Hello", working_dir: CLONE)
    @transcript = plant_pi_session(@file_system, @session, fixture, working_directory: CLONE)
    manager.handle_exit(MockProcessManager::MockStatus.new(exit_code), working_dir: CLONE)
  end

  def session_log
    @log_buffer.flush
    @session.logs.reload.map(&:content).join("\n")
  end

  # --- transient provider failures --------------------------------------------

  test "a 500 is retried with backoff by resuming the same session" do
    decision = pi_turn_ends_with(:server_500)

    assert_equal :continue, decision.action
    resumed = @adapter.resumed_sessions.last
    assert_equal @session.reload.session_id, resumed[:session_id]
    assert AutomatedPrompts.system_recovery?(resumed[:prompt])
    assert_equal 1, ApiErrorRetryService::BUDGET.count_for(@session)
    assert_match(/API server error detected - attempting auto-retry 1\/6/, session_log)
  end

  test "a 502 whose body is HTML rather than JSON is retried just the same" do
    assert_equal :continue, pi_turn_ends_with(:bad_gateway_502).action
    assert_equal 1, ApiErrorRetryService::BUDGET.count_for(@session.reload)
  end

  test "a 503 is retried" do
    assert_equal :continue, pi_turn_ends_with(:overloaded_503).action
    assert_equal 1, ApiErrorRetryService::BUDGET.count_for(@session.reload)
  end

  # Pi's provider 429s are not pressure on the Anthropic API, which is what the
  # fleet-wide tracker measures.
  test "a 429 Pi could not outlast is retried as a rate limit, without pressuring the Claude fleet" do
    @rate_limit_tracker.expects(:record_event).never

    decision = pi_turn_ends_with(:rate_limit_429)

    assert_equal :continue, decision.action
    assert_match(/Rate limit detected - attempting auto-retry 1\/6/, session_log)
  end

  # There is no Pi account pool to rotate into and no Pi quota snapshot to wake
  # on, so a credit exhaustion takes the same bounded backoff rather than a park
  # nothing would ever end.
  test "an insufficient-quota 429 is retried rather than parked on a quota that nothing tracks" do
    decision = pi_turn_ends_with(:insufficient_quota_429)

    assert_equal :continue, decision.action
    assert_not @session.reload.metadata["pending_sleep"]
    assert_nil @session.metadata["last_quota_limit_at"]
  end

  test "a dropped stream and a refused connection are retried like a 5xx" do
    %i[stream_terminated connection_error].each do |fixture|
      setup_fresh_session
      assert_equal :continue, pi_turn_ends_with(fixture).action, fixture.to_s
      assert_equal 1, ApiErrorRetryService::BUDGET.count_for(@session.reload), fixture.to_s
    end
  end

  test "the same dead turn is not retried twice, but the next failed turn is" do
    # The dead turn is failed and named, but it is not an unknown failure mode.
    UnclassifiedFailureReporter.expects(:report).never

    pi_turn_ends_with(:server_500)
    assert_equal 1, ApiErrorRetryService::BUDGET.count_for(@session.reload)

    # The resumed process dies before Pi writes anything new: the transcript still
    # ends on the 500 that was already retried, so nothing may claim it again.
    decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: CLONE)
    assert_equal :failed, decision.action
    assert_match(/The server had an error while processing your request/, decision.error_message)
    assert_equal 1, @adapter.resumed_sessions.size

    # Whereas a resumed turn that fails again is a new failure, and is retried.
    @session.update!(status: :running)
    append_pi_session(@file_system, @transcript, :overloaded_503, @session)
    decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: CLONE)
    assert_equal :continue, decision.action
    assert_equal 2, ApiErrorRetryService::BUDGET.count_for(@session.reload)
  end

  test "a retry budget that is spent fails the session rather than looping" do
    @session.merge_metadata!(ApiErrorRetryService::BUDGET.key => ApiErrorRetryService::BUDGET.max)

    decision = pi_turn_ends_with(:server_500)

    assert_equal :failed, decision.action
    assert_equal "API error retry limit exhausted", decision.error_message
    assert_empty @adapter.resumed_sessions
  end

  # --- what is terminal by design ---------------------------------------------

  # PiAuthProvider pools no accounts, so there is nothing to rotate to and no
  # credential to rewrite. Failing while naming the provider's own words is the
  # honest end; rotating into an empty pool is not.
  test "a 401 fails the session naming the provider, without rotating or paging" do
    UnclassifiedFailureReporter.expects(:report).never

    decision = pi_turn_ends_with(:unauthorized_401)

    assert_equal :failed, decision.action
    assert_match(/Incorrect API key provided/, decision.error_message)
    assert_empty @adapter.resumed_sessions, "there is no Pi account pool to rotate into"
    assert_equal 0, AccountRotationEvent.where(runtime: "pi").count
  end

  test "a 403 ends the same way" do
    assert_equal :failed, pi_turn_ends_with(:forbidden_403).action
    assert_empty @adapter.resumed_sessions
  end

  # Pi has no `/compact` and does not compact on a plain resume either, so there
  # is no recovery to spend the budget on. Failing names the condition; retrying
  # would re-send a conversation that is already too long, one turn longer.
  test "a context-length failure fails the session rather than resuming into a longer prompt" do
    UnclassifiedFailureReporter.expects(:report).never

    decision = pi_turn_ends_with(:context_length_400)

    assert_equal :failed, decision.action
    assert_match(/maximum context length/, decision.error_message)
    assert_empty @adapter.resumed_sessions
    assert_nil @session.reload.metadata["pending_compact_continuation"]
    assert_equal 0, ContextLengthRetryService::BUDGET.count_for(@session)
  end

  # --- what is genuinely unknown ----------------------------------------------

  test "an error no recovery path owns fails the session and pages with Pi's own words" do
    UnclassifiedFailureReporter.expects(:report).with do |kind:, output:, **|
      kind == "terminal API error" && output.to_s.include?("Invalid value for 'temperature'")
    end

    decision = pi_turn_ends_with(:bad_request_400)

    assert_equal :failed, decision.action
    assert_empty @adapter.resumed_sessions
  end

  # The flip of #classifies_exits? is what makes this reachable: a Pi exit that
  # nothing claims used to log and stop, because every ordinary Pi failure landed
  # there. Now the ordinary ones are classified, so what is left is news.
  test "a non-zero exit with no recorded error is an unclassified exit and pages" do
    UnclassifiedFailureReporter.expects(:report).with do |kind:, **|
      kind == "process exit"
    end

    manager.spawn(prompt: "Hello", working_dir: CLONE)
    plant_pi_session(@file_system, @session, :completed, working_directory: CLONE)
    decision = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: CLONE)

    assert_equal :failed, decision.action
  end

  # --- turns that really did complete -----------------------------------------

  test "a completed turn still comes to rest normally" do
    UnclassifiedFailureReporter.expects(:report).never

    decision = pi_turn_ends_with(:completed)

    assert_equal :needs_input, decision.action
    assert_empty @adapter.resumed_sessions
    assert_match(/Process exited successfully/, session_log)
  end

  # Pi retries a 5xx several times itself. A run whose own retry succeeded ends
  # on the answer, and failing or retrying it would be wrong.
  test "an error Pi recovered from on its own is a completed turn" do
    decision = pi_turn_ends_with(:error_then_completed)

    assert_equal :needs_input, decision.action
    assert_empty @adapter.resumed_sessions
  end

  # --- transcripts that are not fully written ----------------------------------

  test "a half-flushed final record does not hide the error the turn died on" do
    manager.spawn(prompt: "Hello", working_dir: CLONE)
    plant_pi_session(@file_system, @session, working_directory: CLONE,
      content: pi_session_for(:server_500, @session.session_id) + %({"type":"message","id":"partia))

    assert_equal :continue, manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: CLONE).action
  end

  # A 500 whose prose happens to name context_length_exceeded is a retryable 5xx.
  # Reading the phrase as a substring would have sent it to a compaction path Pi
  # does not have.
  test "prose naming context_length_exceeded under a 5xx is retried, not treated as a context failure" do
    decision = pi_turn_ends_with(:server_500_context_prose)

    assert_equal :continue, decision.action
    assert AutomatedPrompts.system_recovery?(@adapter.resumed_sessions.last[:prompt])
    assert_equal 1, ApiErrorRetryService::BUDGET.count_for(@session.reload)
  end

  private

  # A second session in one test, for the cases that assert the same thing about
  # two fixtures without letting the first one's budget leak into the second.
  def setup_fresh_session
    @session = Session.create!(
      prompt: "Pi test prompt",
      agent_runtime: "pi",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => CLONE, "working_directory" => CLONE },
      transcript: { "type" => "user", "message" => { "content" => "Pi test prompt" } }.to_json
    )
    @log_buffer = LogBuffer.new(@session)
    @adapter = MockPiRuntimeAdapter.new
    @manager = nil
  end
end
