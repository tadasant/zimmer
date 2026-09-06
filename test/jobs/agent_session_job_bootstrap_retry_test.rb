# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_file_system_adapter"
require_relative "../support/mock_claude_cli_adapter"

# A session killed before it did anything must be startable again.
#
# THE OUTAGE THESE PIN (#785). On 2026-09-02 an OverlayFS `EXDEV` came out of
# the AIR CLI's install swap — `Invalid cross-device link @ rb_file_s_rename -
# (/opt/air-cli/node_modules, /opt/air-cli/.retired/node_modules)` — for 45
# minutes. `AirPrepareService.ensure_air_installed!` rescues `SystemCallError`
# and re-raises it as `AirPrepareError`; that class is in neither of
# `AgentSessionJob`'s two prepare rescues, so it reached #perform's catch-all,
# which stamped `failure_reason: "exception"` and called `fail!`.
#
# 14+ sessions went terminal in that window, every one of them killed before it
# had taken a single turn. Three were the only live shepherd for an open PR; one
# was the session spawned to fix the underlying bug. Nothing retries `failed`
# and `Sessions::StartNow` refuses it, so they sat there for about seven hours
# until a human-run sweep restarted them.
#
# `AirPrepareService`'s own [5, 10, 20] ladder could not have caught it: that
# ladder wraps the `air prepare` SUBPROCESS, and this was a Ruby-side raise in
# the install that runs before it.
#
# What these tests hold is the boundary, in both directions. Before the first
# agent turn: retried, bounded, and loud once the budget is spent. During a
# turn: failed, exactly as today.
class AgentSessionJobBootstrapRetryTest < ActiveJob::TestCase
  CLONE_PATH = "/tmp/bootstrap-retry-test-clone"

  # The message Ruby actually produces for the rename in
  # AirPrepareService.swap_staged_install!.
  EXDEV_MESSAGE =
    "Invalid cross-device link @ rb_file_s_rename - " \
    "(/opt/air-cli/node_modules, /opt/air-cli/.retired/node_modules)"

  setup do
    @session = Session.create!(
      prompt: "Fix the auth bug",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      # A session with at least one MCP server is the one that actually runs
      # `air prepare`; an empty-catalog session takes the baseline branch and
      # never gets near the install.
      mcp_servers: [ "zimmer-self-session" ],
      catalog_skills: [],
      status: :waiting
    )
  end

  # ---------------------------------------------------------------------------
  # 1. The reproduction — the real install path, raising the real fault shape
  # ---------------------------------------------------------------------------

  test "an EXDEV install failure leaves the session waiting, not failed" do
    run_start_that_dies_in_the_air_install

    @session.reload
    assert_equal "waiting", @session.status,
                 "a session killed before it did any work must stay startable; `failed` is terminal and " \
                 "nothing retries it"
    assert_nil @session.metadata["failure_reason"],
               "nothing failed — the turn is being run again"
  end

  # The fault has to arrive as the real thing: a SystemCallError raised inside
  # the install, converted by AirPrepareService's own rescue. Nothing here
  # stubs `prepare!`.
  test "the failure really is the EXDEV one, converted by AirPrepareService itself" do
    logs = run_start_that_dies_in_the_air_install

    line = logs.find { |entry| entry.content.include?("stopped before the agent started") }
    assert_not_nil line, "the session's own timeline has to say why it is still queued"
    assert_includes line.content, "AirPrepareService::AirPrepareError"
    assert_includes line.content, "Invalid cross-device link"
    assert_equal "warning", line.level,
                 "a fault that is about to be retried automatically must not page on every attempt"
  end

  test "the session's configuration survives the retry intact" do
    run_start_that_dies_in_the_air_install

    @session.reload
    assert_equal "Fix the auth bug", @session.prompt
    assert_equal [ "zimmer-self-session" ], @session.mcp_servers
    assert_equal "https://github.com/test/repo.git", @session.git_root
    assert_equal "main", @session.branch
  end

  test "a replacement turn is queued, and the session points at it" do
    assert_enqueued_jobs 1, only: AgentSessionJob do
      run_start_that_dies_in_the_air_install
    end

    queued = enqueued_jobs.find { |job| job["job_class"] == "AgentSessionJob" }
    assert_equal @session.id, queued["arguments"].first,
                 "the replacement is the same turn, not an approximation of it"
    assert_nil queued["arguments"][1], "and it is still a fresh start, carrying no prompt of its own"
    assert_equal queued["job_id"], @session.reload.running_job_id,
                 "orphan detection and StalledSessionStart both read running_job_id; a blank one here " \
                 "invites a second, concurrent start"
  end

  # #perform reuses an existing clone when it finds one, and that arm does not
  # run `air prepare` at all — it assumes the clone was prepared by whatever
  # made it. For a bootstrap failure that is false, so a retry that kept the
  # clone would skip the very step that failed.
  test "the partial setup is discarded so the retry re-runs the step that failed" do
    run_start_that_dies_in_the_air_install

    @session.reload
    assert_nil @session.session_id, "a fresh runtime session id has to be minted by the next attempt"
    assert_nil @session.metadata["clone_path"],
               "leaving the clone behind routes the retry down the reuse arm, which never calls `air prepare`"
    assert_nil @session.metadata["working_directory"]
  end

  test "the retry is counted, so the budget can be spent" do
    run_start_that_dies_in_the_air_install

    assert_equal 1, @session.reload.metadata["bootstrap_retry_count"]
    assert @session.metadata["last_bootstrap_retry_at"].present?
  end

  # ---------------------------------------------------------------------------
  # 2. Budget exhaustion — what happens after the last retry
  # ---------------------------------------------------------------------------

  test "a session that spends its whole budget fails loudly rather than retrying forever" do
    @session.merge_metadata!("bootstrap_retry_count" => AgentSessionJob::MAX_BOOTSTRAP_RETRIES)

    assert_no_enqueued_jobs only: AgentSessionJob do
      run_start_that_dies_in_the_air_install(swallow: true)
    end

    @session.reload
    assert_equal "failed", @session.status
    assert_equal "bootstrap_retries_exhausted", @session.metadata["failure_reason"],
                 "the failure that outlived five automatic attempts must not read like the first one"
    assert_equal "AirPrepareService::AirPrepareError", @session.metadata["exception_class"]
    assert_includes @session.metadata["exception_message"], "Invalid cross-device link"
  end

  # The re-raise IS the paging path — config/initializers/sentry.rb says so in as
  # many words, and ActiveJob logs the terminal failure at ERROR, which is what
  # the zimmer_backend_log_errors Grafana rule reads. Retrying quietly is only
  # safe because giving up is loud.
  test "the exhausted failure is re-raised into the exception reporter" do
    @session.merge_metadata!("bootstrap_retry_count" => AgentSessionJob::MAX_BOOTSTRAP_RETRIES)

    raised = assert_raises(AirPrepareService::AirPrepareError) do
      run_start_that_dies_in_the_air_install(swallow: false)
    end
    assert_includes raised.message, "Invalid cross-device link"

    errors = @session.logs.reload.select { |entry| entry.level == "error" }
    assert errors.any? { |entry| entry.content.include?("retry budget is spent") },
           "the session's own page has to say the budget ran out, not just that something raised"
  end

  # A failed session is only findable if the human who finds it can act on it.
  # `bootstrap_retries_exhausted` is a PRE_PROMPT_FAILURE_REASON, and by
  # construction it can only be stamped on a session before its first agent
  # turn — so the Restart button re-runs the whole pipeline instead of trying to
  # `--resume` a conversation that was never written (#401's wedge).
  test "an exhausted session is restartable from scratch" do
    @session.merge_metadata!("bootstrap_retry_count" => AgentSessionJob::MAX_BOOTSTRAP_RETRIES)
    run_start_that_dies_in_the_air_install

    @session.reload
    assert @session.failed_before_initial_prompt?
    assert @session.needs_restart_from_scratch?,
           "the one action a human takes on this session has to be the one that works"
  end

  # `failure_reason.humanize` would render "Bootstrap retries exhausted", which
  # names the mechanism and hides both facts a reader needs.
  test "the failure block tells a human what happened and what to do" do
    @session.merge_metadata!("bootstrap_retry_count" => AgentSessionJob::MAX_BOOTSTRAP_RETRIES)
    run_start_that_dies_in_the_air_install

    summary = @session.reload.failure_summary
    assert_includes summary, "never started"
    assert_includes summary, "#{AgentSessionJob::MAX_BOOTSTRAP_RETRIES + 1} times"
    assert_includes summary, "restart it"
    assert_includes summary, "AirPrepareService::AirPrepareError"
    assert @session.shows_failure_details?
  end

  # `Session::PRE_PROMPT_FAILURE_REASONS` carries literals for every job-side
  # reason, by the convention its own comment states. This is the thing that
  # notices when the two drift.
  test "the exhausted reason is one the restart paths recognise" do
    assert_includes Session::PRE_PROMPT_FAILURE_REASONS,
                    AgentSessionJob::BOOTSTRAP_EXHAUSTED_FAILURE_REASON
    assert_includes Session::STALE_RETRY_METADATA_KEYS, AgentSessionJob::BOOTSTRAP_RETRY_COUNT
    assert_includes Session::STALE_RETRY_METADATA_KEYS, AgentSessionJob::BOOTSTRAP_RETRY_AT
  end

  test "a restart hands the session a fresh budget" do
    @session.merge_metadata!("bootstrap_retry_count" => 3)
    @session.remove_metadata!(Session::STALE_RETRY_METADATA_KEYS)

    assert_nil @session.reload.metadata["bootstrap_retry_count"],
               "a person restarting a session by hand is not attempt four of five"
  end

  # ---------------------------------------------------------------------------
  # 3. The negative case — a failure DURING a turn must still fail the session
  # ---------------------------------------------------------------------------

  test "a session whose agent has already spoken still fails" do
    ran = Session.create!(
      prompt: "Fix the auth bug",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      mcp_servers: [ "zimmer-self-session" ],
      status: :waiting,
      # The two signals `Session#before_first_agent_turn?` reads. Either one on
      # its own is enough to disqualify the session; this is both.
      transcript: { "type" => "assistant", "message" => { "content" => "On it." } }.to_json,
      metadata: { "runtime_started" => true }
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      run_start_that_dies_in_the_air_install(session: ran)
    end

    ran.reload
    assert_equal "failed", ran.status
    assert_equal "exception", ran.metadata["failure_reason"],
                 "a turn that dies after an agent has spoken is a runtime fault with a transcript to read"
  end

  test "a session that has a transcript but no runtime_started marker still fails" do
    ran = Session.create!(
      prompt: "Fix the auth bug",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      mcp_servers: [ "zimmer-self-session" ],
      status: :waiting,
      transcript: { "type" => "assistant", "message" => { "content" => "On it." } }.to_json
    )

    run_start_that_dies_in_the_air_install(session: ran)

    assert_equal "failed", ran.reload.status,
                 "the transcript is the runtime's own output; a session holding one has had an agent " \
                 "speak into it whatever the metadata says"
  end

  # `retry_on` covers three transient classes and #perform re-raises, so a turn
  # dying on one of them already has another attempt at it. A second ladder
  # underneath that one would double-run the setup.
  test "a turn whose exception is already going to be retried is not re-queued again" do
    job = build_job(@session)
    job.stubs(:another_attempt_queued?).returns(true)

    assert_no_enqueued_jobs only: AgentSessionJob do
      run_job(job, @session)
    end

    assert_equal "failed", @session.reload.status
    assert_equal "exception", @session.metadata["failure_reason"]
  end

  # An undelivered prompt is Sessions::ParkUndeliveredTurn's case (#439) and has
  # to stay there: this retry clears the runtime session id, which routes the
  # replacement down #perform's fresh-start reclassification — and that arm
  # drops the follow-up text when the session already has a prompt of its own.
  test "a turn carrying a human's prompt is parked, not retried" do
    @session.update!(session_id: SecureRandom.uuid, status: :needs_input)
    @session.merge_metadata!("clone_path" => CLONE_PATH, "working_directory" => CLONE_PATH)
    @session.update!(transcript: { "type" => "user", "message" => { "content" => "hi" } }.to_json)
    @session.deliver_follow_up!("Please open the PR")

    job = build_job(@session, "Please open the PR")
    run_job(job, @session, prompt: "Please open the PR")

    @session.reload
    assert_equal "needs_input", @session.status
    assert_equal Sessions::ParkUndeliveredTurn::FAILURE_REASON, @session.metadata["failure_reason"]
    assert_equal "Please open the PR", @session.undelivered_prompt,
                 "the retry must never be the thing that swallows a human's message"
  end

  private

  # Drive the real install path: the fast-path marker is pointed at a name that
  # cannot exist, so `ensure_air_installed!` takes the lock and calls
  # `install_air_cli!` — which raises the EXDEV that
  # `swap_staged_install!`'s `File.rename` raised in production. The conversion
  # to `AirPrepareError` at AirPrepareService's own rescue is NOT stubbed; that
  # is the code path under test.
  def run_start_that_dies_in_the_air_install(session: @session, swallow: true)
    exdev = Errno::EXDEV.new(EXDEV_MESSAGE)

    AirPrepareService.stubs(:air_marker_filename)
                     .returns(".air-version-absent-#{SecureRandom.hex(6)}")
    AirPrepareService.stubs(:install_air_cli!).raises(exdev)

    run_job(build_job(session), session, swallow: swallow)
    session.logs.reload
  end

  def build_job(session, prompt = nil)
    job = AgentSessionJob.new(session.id, prompt)
    job.process_manager = MockProcessManager.new
    job.file_system = MockFileSystemAdapter.new
    job.cli_adapter = MockClaudeCliAdapter.new
    job.file_system.mkdir_p(CLONE_PATH)
    job
  end

  # `swallow` is the default because #perform re-raises on the paths that fail,
  # and most of these tests are about the state that raise leaves behind. The
  # retry path does not raise at all, so `assert_raises` cannot be used there —
  # the block below tolerates both.
  def run_job(job, session, prompt: nil, swallow: true)
    cli = job.cli_adapter

    GitCloneService.stub(:create_clone, { clone_path: CLONE_PATH, working_directory: CLONE_PATH }) do
      begin
        job.perform(session.id, prompt)
      rescue StandardError => e
        raise e unless swallow
      end
    end

    assert_empty cli.executed_commands, "the turn must have died before the runtime was reached"
    assert_empty cli.resumed_sessions, "the turn must have died before the runtime was reached"
    cli
  end
end
