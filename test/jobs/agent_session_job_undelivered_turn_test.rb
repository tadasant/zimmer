# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_file_system_adapter"
require_relative "../support/mock_claude_cli_adapter"

# A follow-up that dies before the agent starts must not disappear.
#
# THE BUG THESE PIN (#439). Production session 3949 finished a turn, was
# archived, and was unarchived to receive a follow-up carrying a live user
# request. The unarchive rebuilt the clone; `air prepare` died with ENOENT on the
# agent root's `.mcp.json` (the mass-deletion patch replay of #411, fixed
# separately in #413); #perform's catch-all stamped `failure_reason: "exception"`
# and called `fail!`.
#
# `failed` is not in the `needs_input` action queue the homepage presents as the
# user's to-do list, nothing in Zimmer restarts a session that failed for any
# reason other than `GoodJob::InterruptError`, and the session that had delegated
# the work archived itself seventy seconds after handing off. So the request was
# dropped, in silence, for two days — found by a human sweeping unarchived
# sessions.
#
# What these tests hold is the disposition, not the cause: a turn that raised
# before an agent process existed, carrying a prompt nobody saw, comes to rest
# where a person looks, keeps the prompt, and still reports the fault.
class AgentSessionJobUndeliveredTurnTest < ActiveJob::TestCase
  CLONE_PATH = "/tmp/undelivered-turn-test-clone"

  # The real thing, near enough: `air prepare` exits non-zero with a wall of
  # upstream deprecation warnings and one hard failure buried in it.
  AIR_ENOENT = <<~OUT
    (node:41) [DEP0040] DeprecationWarning: The `punycode` module is deprecated.
    Error: ENOENT: no such file or directory, open '#{CLONE_PATH}/.mcp.json'
  OUT

  setup do
    @session = Session.create!(
      prompt: "Original prompt",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      status: :needs_input,
      # A session with at least one MCP server is the one that actually runs
      # `air prepare` on a follow-up; the empty-catalog session takes the baseline
      # branch instead and never gets near the failure being reproduced.
      mcp_servers: [ "zimmer-self-session" ],
      metadata: {
        "clone_path" => CLONE_PATH,
        "working_directory" => CLONE_PATH,
        "runtime_started" => true,
        "clone_recreated" => true
      },
      transcript: { "type" => "user", "message" => { "content" => "Original prompt" } }.to_json
    )
  end

  # ---------------------------------------------------------------------------
  # The reproduction
  # ---------------------------------------------------------------------------

  test "a follow-up that dies at AIR prepare comes to rest in the action queue, not in failed" do
    deliver_follow_up_that_dies_at_air_prepare

    @session.reload
    assert_equal "needs_input", @session.status,
                 "a dropped request must land in the queue the homepage shows, not in `failed` where nobody looks"
    assert_equal "undelivered_turn", @session.metadata["failure_reason"]
    assert_equal "AirPrepareService::AirPrepareError", @session.metadata["exception_class"]
    assert_includes @session.metadata["exception_message"], ".mcp.json",
                    "the diagnosis must survive — this is the only record of what went wrong"
    assert_nil @session.running_job_id, "a turn that ended must leave no owner on the row"
  end

  test "the undelivered prompt is kept on the session and readable on its timeline" do
    deliver_follow_up_that_dies_at_air_prepare(prompt: "Please open the PR for the auth fix")

    @session.reload
    assert_equal "Please open the PR for the auth fix", @session.undelivered_prompt,
                 "the follow-up arm consumes the delivery marker on the way in, so a boot failure " \
                 "would otherwise lose the user's text with the job"
    assert @session.logs.reload.any? { |entry| entry.content.include?("Please open the PR for the auth fix") },
           "the human recovering this reads the session page, not the metadata column"
  end

  # `pending_follow_up_prompt` is what #perform's follow-up arm prefers over its own
  # argument, so a dead turn's prompt left there is delivered in place of the next
  # real one. Three delivery paths do not stamp the marker, and one of them —
  # EnqueuedMessageProcessorService — is reachable from this park's own `pause!`.
  test "the next prompt cannot lose to the dead one" do
    deliver_follow_up_that_dies_at_air_prepare(prompt: "The turn that died")

    assert_nil @session.reload.metadata["pending_follow_up_prompt"]
  end

  test "a message queued while the turn ran is still the one delivered after the park" do
    @session.enqueued_messages.create!(content: "The message a human sent second", position: 1, status: "pending")

    deliver_follow_up_that_dies_at_air_prepare(prompt: "The turn that died")

    queued = @session.enqueued_messages.reload.first
    assert_not_nil queued, "the park must not consume somebody else's queued message"
    assert_equal "The message a human sent second", queued.content
  end

  test "the session is in the homepage's action queue" do
    deliver_follow_up_that_dies_at_air_prepare

    queued = Session.where(status: :needs_input).pluck(:id)
    assert_includes queued, @session.id
  end

  test "the park announces itself, so a watcher that is not looking at the homepage still hears" do
    fired = nil
    assert_enqueued_jobs 1, only: AoEventTriggerJob do
      deliver_follow_up_that_dies_at_air_prepare
      fired = enqueued_jobs.select { |job| job["job_class"] == "AoEventTriggerJob" }
    end
    assert_equal "session_needs_input", fired.first["arguments"].first,
                 "the settled needs_input fan-out is what reaches a parent session waiting on this one"
  end

  test "no recovery marker is left behind, so no sweep loops on a boot that is deterministically broken" do
    deliver_follow_up_that_dies_at_air_prepare

    assert_nil @session.reload.metadata["paused_by"],
               "`paused_by: recovery` promises a sweep will continue this session; a broken AIR prepare " \
               "would just fail again twelve times and end in the same silence"
  end

  test "the session's own timeline explains what happened and what was kept" do
    deliver_follow_up_that_dies_at_air_prepare

    record = @session.logs.reload.find { |entry| entry.content.include?("stopped before the agent started") }
    assert_not_nil record, "a session in the queue has to say why it is there"
    assert_equal "warning", record.level
    assert_includes record.content, "AirPrepareService::AirPrepareError"
    assert_includes record.content, "never delivered"

    errors = @session.logs.select { |entry| entry.level == "error" }
    assert errors.any? { |entry| entry.content.include?("Error in agent execution") },
           "the operator-facing error line is not suppressed — this changes where the session rests, " \
           "not how loudly the fault is reported"
  end

  # The re-raise is the reporting path — `config/initializers/sentry.rb` says so in
  # as many words, and ActiveJob logs the terminal failure at ERROR, which is what
  # the zimmer_backend_log_errors Grafana rule reads. Parking the session must not
  # buy its visibility by making the fault quieter somewhere else.
  test "the exception is still re-raised into the exception reporter" do
    raised = assert_raises(AirPrepareService::AirPrepareError) do
      deliver_follow_up_that_dies_at_air_prepare(swallow: false)
    end
    assert_includes raised.message, ".mcp.json"
  end

  # ---------------------------------------------------------------------------
  # What must keep failing
  # ---------------------------------------------------------------------------

  test "a first turn that dies at AIR prepare still fails — nobody has been told that work started" do
    fresh = Session.create!(
      prompt: "Original prompt",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      mcp_servers: [ "zimmer-self-session" ],
      status: :waiting
    )

    run_job(fresh, nil)

    fresh.reload
    assert_equal "failed", fresh.status
    assert_equal "exception", fresh.metadata["failure_reason"]
  end

  # `retry_on` covers three transient classes and #perform re-raises, so a turn that
  # dies on one of them has another attempt at this same prompt already queued. The
  # park's own log line promises "nothing is retried", and it has to be true.
  test "a turn whose exception is about to be retried is not parked" do
    deliver_follow_up_that_dies_at_air_prepare(error: Timeout::Error.new("clone timed out"))

    @session.reload
    assert_equal "failed", @session.status,
                 "an ended-turn announcement must not race a retry that is still going to run it"
    assert_equal "exception", @session.metadata["failure_reason"]
  end

  test "a status-summary fork is never parked into the action queue" do
    @session.merge_metadata!(SessionStatusSummaryGenerator::FORK_MARKER => 4242)

    # The summary request, because that is the only turn a fork gets: every other
    # prompt is refused before the runtime now, so a fork could not reach `air
    # prepare` carrying one. See AgentSessionJob#refuse_non_summary_fork_turn.
    deliver_follow_up_that_dies_at_air_prepare(
      prompt: "#{SessionStatusSummaryGenerator::FORK_PROMPT_OPENING} (#4242). It is read at a glance."
    )

    @session.reload
    assert_equal "failed", @session.status,
                 "Zimmer's own bookkeeping must never take a slot in the human's action queue"
    assert_equal "exception", @session.metadata["failure_reason"]
  end

  private

  # The reported flow: an idle session is handed a follow-up (which resumes it and
  # stamps the prompt), the job picks it up, and `air prepare` raises on the way to
  # the spawn — before any agent process exists.
  def deliver_follow_up_that_dies_at_air_prepare(
    prompt: "Please continue with the review", swallow: true, error: nil
  )
    @session.deliver_follow_up!(prompt)
    run_job(@session, prompt, swallow: swallow, error: error)
  end

  # `swallow` is the default because #perform re-raises on purpose (see the test
  # that pins it) and every other test here is about the state that re-raise leaves
  # behind, not about the raise itself.
  def run_job(session, prompt, swallow: true, error: nil)
    cli = MockClaudeCliAdapter.new
    job = AgentSessionJob.new(session.id, prompt)
    job.process_manager = MockProcessManager.new
    job.file_system = MockFileSystemAdapter.new
    job.cli_adapter = cli
    job.file_system.mkdir_p(CLONE_PATH)

    raised = error || AirPrepareService::AirPrepareError.new(
      "AIR prepare failed (exit status 1): #{AIR_ENOENT}"
    )
    AirPrepareService.any_instance.stubs(:prepare!).raises(raised)

    GitCloneService.stub(:create_clone, { clone_path: CLONE_PATH, working_directory: CLONE_PATH }) do
      if swallow
        assert_raises(raised.class) { job.perform(session.id, prompt) }
      else
        job.perform(session.id, prompt)
      end
    end

    assert_empty cli.executed_commands, "the turn must have died before the runtime was reached"
    assert_empty cli.resumed_sessions, "the turn must have died before the runtime was reached"
    cli
  end
end
