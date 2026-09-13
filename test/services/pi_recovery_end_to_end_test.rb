# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

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

  # OpenRouter's own rate-limit wording, which Pi itself retried four times.
  test "an OpenRouter rate-limit 429 still takes the ordinary backoff, not a park" do
    decision = pi_turn_ends_with(:rate_limit_429_openrouter)

    assert_equal :continue, decision.action
    assert_equal 1, ApiErrorRetryService::BUDGET.count_for(@session.reload)
    assert_nil ProviderQuotaWallPark.streak(@session)
    assert_equal 0, wake_triggers.count
  end

  test "a timeout, a dropped stream and a refused connection are retried like a 5xx" do
    %i[timeout_408 stream_terminated connection_error].each do |fixture|
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

  # --- quota walls: budget pacing, not failure ---------------------------------

  # Pi has no pool to rotate through and no snapshot to wake on, so the wall is
  # parked on a timed re-check: the session sleeps, and a one-time wake resumes
  # it. Nothing fails, no retry budget is spent, and nothing pages.
  test "a 402 parks the session on a timed re-check instead of failing it" do
    UnclassifiedFailureReporter.expects(:report).never

    freeze_time do
      decision = pi_turn_ends_with(:insufficient_credits_402)

      assert_equal :needs_input, decision.action
      assert_match(/Provider quota wall — session parked, re-checking at #{15.minutes.from_now.utc.iso8601}/, decision.error_message)
      assert_match(/Insufficient credits/, decision.error_message)

      @session.reload
      assert_equal 0, ApiErrorRetryService::BUDGET.count_for(@session), "a quota wall must not spend the API-error budget"
      assert_empty @adapter.resumed_sessions, "nothing resumes until the re-check"
      assert_equal 0, AccountRotationEvent.where(runtime: "pi").count
      assert_nil @session.metadata["auth_outage_reason"], "an auth-outage park would wait on a pool Pi does not have"
      assert @session.metadata["pending_sleep"], "the wake's pending sleep carries the session to waiting"

      streak = ProviderQuotaWallPark.streak(@session)
      assert_equal 1, streak["parks"]
      assert_equal 15.minutes.from_now.utc.iso8601, streak["next_check_at"]

      trigger = wake_triggers.sole
      assert_equal 15.minutes.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S"),
        trigger.trigger_conditions.first.configuration["scheduled_at"]
      assert AutomatedPrompts.system_recovery?(trigger.prompt_template)

      assert_match(/Provider quota wall: .* No retry budget spent\. Parked — Zimmer re-checks at/, session_log)
      assert_enqueued_jobs 1, only: SendPushNotificationJob
    end
  end

  test "a quota-worded 429, in either dialect, parks the same way" do
    UnclassifiedFailureReporter.expects(:report).never

    %i[insufficient_quota_429 quota_exceeded_429_gateway].each do |fixture|
      setup_fresh_session
      decision = pi_turn_ends_with(fixture)

      assert_equal :needs_input, decision.action, fixture.to_s
      assert_equal 0, ApiErrorRetryService::BUDGET.count_for(@session.reload), fixture.to_s
      assert_equal 1, ProviderQuotaWallPark.streak(@session)["parks"], fixture.to_s
      assert_equal 1, wake_triggers.count, fixture.to_s
    end
  end

  # The whole loop, with nothing but the process and the clock stubbed: the park
  # comes to rest in `waiting`, the scheduler fires the wake on time, and the wake
  # hands the session a recovery turn on its own session id.
  test "the parked session sleeps, and the re-check wakes it without a human" do
    AgentSessionJob.stubs(:enqueue_with_prompt).returns(OpenStruct.new(job_id: "job-quota-wall"))

    pi_turn_ends_with(:insufficient_credits_402)
    @session.reload.pause!
    assert @session.reload.waiting?, "the park must come to rest asleep, not in the human's queue"

    travel_to(5.minutes.from_now) { ScheduleTriggerJob.perform_now }
    assert_nil @session.reload.metadata["pending_follow_up_prompt"], "not before the re-check is due"

    travel_to(16.minutes.from_now) { ScheduleTriggerJob.perform_now }
    prompt = @session.reload.metadata["pending_follow_up_prompt"]
    assert AutomatedPrompts.system_recovery?(prompt), "the re-check should have resumed the session"
    assert_match(/provider quota-wall re-check \(check 1\)/, prompt)
  end

  # Each re-check that meets the wall again climbs the ladder. The human hears
  # about the streak once, not on every rung.
  test "a wall still standing at the re-check parks one rung higher, and notifies once" do
    freeze_time do
      pi_turn_ends_with(:insufficient_credits_402)

      # The re-check's turn: Pi appends to the same file and meets the wall again.
      @session.update!(status: :running)
      append_pi_session(@file_system, @transcript, :quota_exceeded_429_gateway, @session)
      decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: CLONE)

      assert_equal :needs_input, decision.action
      streak = ProviderQuotaWallPark.streak(@session.reload)
      assert_equal 2, streak["parks"]
      assert_equal 30.minutes.from_now.utc.iso8601, streak["next_check_at"]
      assert_equal 0, ApiErrorRetryService::BUDGET.count_for(@session)
      assert_enqueued_jobs 1, only: SendPushNotificationJob
    end
  end

  # A turn that gets through is the evidence the wall is gone, so the next wall
  # starts the ladder again rather than inheriting the old streak's rung.
  test "a turn that gets through after the top-up ends the streak" do
    pi_turn_ends_with(:insufficient_credits_402)
    assert ProviderQuotaWallPark.streak(@session.reload)

    # The real binary's run: the same session id, a 402, then — balance restored —
    # the recovery turn answered.
    @session.update!(status: :running)
    plant_pi_session(@file_system, @session, :insufficient_credits_402_then_topped_up, working_directory: CLONE)
    decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: CLONE)

    assert_equal :needs_input, decision.action
    assert_nil decision.error_message
    assert_nil ProviderQuotaWallPark.streak(@session.reload)
    assert_match(/Process exited successfully/, session_log)
  end

  # What bounds a balance nobody refills: past the ceiling Zimmer stops arming
  # re-checks and leaves the session for a human, still without failing or paging.
  test "a wall that outlasts the ceiling stops re-checking and leaves the session for a human" do
    UnclassifiedFailureReporter.expects(:report).never
    @session.merge_metadata!(ProviderQuotaWallPark::METADATA_KEY => {
      "started_at" => (ProviderQuotaWallPark::CEILING - 1.hour).ago.utc.iso8601,
      "parks" => 24,
      "next_check_at" => Time.current.utc.iso8601,
      "message" => "402: earlier"
    })

    decision = pi_turn_ends_with(:insufficient_credits_402)

    assert_equal :needs_input, decision.action
    assert_match(/still standing after 7 days — re-checks stopped/, decision.error_message)
    assert_equal 0, wake_triggers.count, "no further re-check is armed"
    assert_not @session.reload.metadata["pending_sleep"]
    assert_nil ProviderQuotaWallPark.streak(@session), "a human's resume earns a fresh ladder"
    assert_equal 0, ApiErrorRetryService::BUDGET.count_for(@session)
    assert_match(/Zimmer has stopped re-checking/, session_log)
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

  test "a wording nothing recognizes fails the session and pages with Pi's own words" do
    UnclassifiedFailureReporter.expects(:report).with do |kind:, output:, **|
      kind == "terminal API error" && output.to_s.include?(PiSessionFixtures::UNKNOWN_WORDING)
    end

    manager.spawn(prompt: "Hello", working_dir: CLONE)
    plant_pi_session(@file_system, @session, working_directory: CLONE,
      content: pi_session_with_unknown_error(@session.session_id))
    decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: CLONE)

    assert_equal :failed, decision.action
    assert_empty @adapter.resumed_sessions
  end

  # The case that decides whether this classification is safe to ship: production
  # Pi runs on OpenRouter, whose 400 carries a numeric `"code":400` and nothing
  # Zimmer can match. It must fail QUIETLY — a page here would fire on every long
  # Pi session that outgrows its window.
  test "a rejection Zimmer cannot name more precisely fails without paging" do
    UnclassifiedFailureReporter.expects(:report).never

    %i[bad_request_400 openrouter_context_400].each do |fixture|
      setup_fresh_session
      decision = pi_turn_ends_with(fixture)

      assert_equal :failed, decision.action, fixture.to_s
      assert_empty @adapter.resumed_sessions, fixture.to_s
    end
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

  def wake_triggers
    Trigger.where(last_session_id: @session.id, reuse_session: true)
  end

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
