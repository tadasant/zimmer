# frozen_string_literal: true

require "test_helper"
require_relative "../support/mock_process_manager"

# GitHub issue #1166 — what happens when the MCP server a session loses is the one
# carrying its own lifecycle.
#
# #521 established the general answer: a lost server costs the capability, not the
# session, and `test/jobs/agent_session_job_test.rb` pins that. These tests pin the
# one carve-out. When the tools that are gone are `action_session` (archive,
# `message_parent`), the `wake_me_up_*` tools and `start_session`, resuming the
# session is not a smaller failure than stopping it — it is a session that looks
# healthy, runs to completion, and does nothing, then gets re-prompted and does
# nothing again.
class AgentSessionJobRequiredMcpTest < ActiveJob::TestCase
  ZIMMER_SELF_SESSION = SelfSessionInjector::SELF_SESSION_SERVER_NAME

  setup do
    @session = Session.create!(
      prompt: "Route the alert",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: { "type" => "user", "message" => { "content" => "Route the alert" } }.to_json
    )
    @session.update!(custom_metadata: { "injected_mcp_servers" => [ ZIMMER_SELF_SESSION ] })
  end

  def build_job
    job = AgentSessionJob.new
    job.process_manager = MockProcessManager.new
    job.broadcast_service = BroadcastService.new
    job
  end

  def flag_failure!(server_name, error:, retry_count: nil, metadata: {})
    attributes = {
      custom_metadata: (@session.custom_metadata || {}).merge(
        "should_fail_session" => true,
        "mcp_failed_servers" => [ { "name" => server_name, "status" => "failed", "error" => error } ],
        "mcp_failure_reason" => "MCP server(s) failed to connect: #{server_name}"
      )
    }
    attributes[:metadata] = (@session.metadata || {}).merge(metadata).tap do |m|
      m["mcp_retry_count"] = retry_count if retry_count
    end
    @session.update!(attributes)
  end

  test "a required server that exhausts the ladder fails the session instead of resuming without it" do
    flag_failure!(
      ZIMMER_SELF_SESSION,
      error: "SdkHttpError dialing https://zimmer.example.com/mcp?session_id=#{@session.id}",
      retry_count: RetryBudget::MCP_CONNECTION.max
    )
    log_buffer = LogBuffer.new(@session)
    agent_jobs_before = enqueued_jobs.count { |j| j["job_class"] == "AgentSessionJob" }

    rails_errors = []
    rails_warns = []
    result = nil
    Rails.logger.stub(:error, ->(msg) { rails_errors << msg }) do
      Rails.logger.stub(:warn, ->(msg) { rails_warns << msg }) do
        result = build_job.send(:check_and_handle_mcp_failure, @session, 12345, log_buffer)
      end
    end

    assert_equal true, result
    @session.reload

    assert_equal "failed", @session.status,
      "a session with no way to archive, hand off or spawn must not be resumed to run silently"
    assert_equal AgentSessionJob::REQUIRED_MCP_SERVER_LOST_FAILURE_REASON, @session.metadata["failure_reason"]
    assert_equal [ ZIMMER_SELF_SESSION ], @session.metadata[AgentSessionJob::REQUIRED_MCP_SERVERS_LOST_KEY]
    assert_nil @session.running_job_id

    # The write-off record is still written — it is what names the loss on the
    # session page, and what McpStatusPersisting retires when the server comes back.
    assert_equal [ ZIMMER_SELF_SESSION ], @session.degraded_mcp_server_names

    assert_equal agent_jobs_before, enqueued_jobs.count { |j| j["job_class"] == "AgentSessionJob" },
      "the session must not be resumed"

    # The two surfaces a human reads.
    assert_includes @session.failure_summary, ZIMMER_SELF_SESSION
    # One clause: SessionTitleJob titles the session with the first 100 characters of
    # it and SendPushNotificationJob builds the push body from the first 200, with
    # the detail appended after — so a paragraph here costs the per-server error.
    assert_operator @session.failure_summary.length, :<=, 100
    assert_includes @session.failure_detail.to_s, "SdkHttpError"
    assert_includes @session.failure_detail.to_s, "Restart it once"

    log_buffer.flush
    log_text = @session.logs.pluck(:content).join("\n")
    assert_match(/cannot run without them/, log_text)

    assert_empty rails_errors,
      "one session losing one server must not trip the global prod-ERROR alert"
    assert rails_warns.any? { |m| m.to_s.include?("Required MCP server(s) lost") && m.to_s.include?("session_id=#{@session.id}") },
      "the loss must stay greppable in obs; got: #{rails_warns.inspect}"
    assert_empty rails_warns.select { |m| m.to_s.include?("session continues") },
      "one handshake must not produce two contradictory lines about the same session"
  end

  test "the first failure of a required server still rides the retry ladder" do
    # Most connect failures are a server still starting after a deploy. Failing on
    # the first one would turn every deploy-window flap into a dead session.
    flag_failure!(ZIMMER_SELF_SESSION, error: "Connection failed after 431ms")
    log_buffer = LogBuffer.new(@session)

    assert_equal true, build_job.send(:check_and_handle_mcp_failure, @session, 12345, log_buffer)

    @session.reload
    assert_equal "needs_input", @session.status
    assert_equal "mcp_retry", @session.metadata["paused_by"]
    assert_equal 1, @session.metadata["mcp_retry_count"]
    assert_nil @session.metadata["failure_reason"]
    assert_empty @session.degraded_mcp_servers
    assert_enqueued_with(job: AgentSessionJob)
  end

  test "an auth-shaped error on a required server rides the ladder instead of fast-failing" do
    # AUTH_ERROR_PATTERN is a substring match and a transport error quotes the URL it
    # was dialing — which ends `&session_id=<id>`. So a session whose id merely
    # CONTAINS "401" reads as an auth failure on an ordinary connect error, and the
    # no-retry route for a rejected static credential would kill it for its id.
    # Zimmer's own key is also the one credential a retry can fix: it is resolved
    # fresh on every spawn, so a rotation or a mid-deploy blip heals on the ladder.
    flag_failure!(
      ZIMMER_SELF_SESSION,
      error: "SdkHttpError dialing https://zimmer.example.com/mcp?tool_groups=self_session&session_id=4013 (401)"
    )
    log_buffer = LogBuffer.new(@session)

    assert_equal true, build_job.send(:check_and_handle_mcp_failure, @session, 12345, log_buffer)

    @session.reload
    assert_equal "needs_input", @session.status, "an auth-shaped error must not skip the ladder here"
    assert_equal 1, @session.metadata["mcp_retry_count"]
    assert_nil @session.metadata["failure_reason"]
    assert_empty @session.degraded_mcp_servers, "nothing is written off on the first attempt"
  end

  test "an auth-shaped error on a required server is still fatal once the ladder is spent" do
    flag_failure!(
      ZIMMER_SELF_SESSION,
      error: "SdkHttpError dialing https://zimmer.example.com/mcp?session_id=4013 (401)",
      retry_count: RetryBudget::MCP_CONNECTION.max
    )
    log_buffer = LogBuffer.new(@session)

    assert_equal true, build_job.send(:check_and_handle_mcp_failure, @session, 12345, log_buffer)

    @session.reload
    assert_equal "failed", @session.status
    assert_equal AgentSessionJob::REQUIRED_MCP_SERVER_LOST_FAILURE_REASON, @session.metadata["failure_reason"]
  end

  # The write-off record deliberately survives a restart (Session#degraded_mcp_servers
  # says why), and the already-degraded short-circuit at the top of
  # check_and_handle_mcp_failure consumes the flag and lets the turn run. Together
  # those would hand a human who restarts a still-broken session exactly the silent
  # no-op this whole change exists to end — reached through the fix for it.
  test "a restart with the required server still down is failed again, not resumed silently" do
    flag_failure!(
      ZIMMER_SELF_SESSION,
      error: "Connection failed after 94ms",
      retry_count: RetryBudget::MCP_CONNECTION.max
    )
    build_job.send(:check_and_handle_mcp_failure, @session, 12345, LogBuffer.new(@session))
    assert_equal "failed", @session.reload.status
    assert_equal [ ZIMMER_SELF_SESSION ], @session.degraded_mcp_server_names

    # What a restart does, and then the same server failing again on the new spawn.
    @session.remove_metadata!(Session::STALE_RETRY_METADATA_KEYS)
    @session.update!(status: :running)
    flag_failure!(ZIMMER_SELF_SESSION, error: "Connection failed after 94ms")
    log_buffer = LogBuffer.new(@session)

    assert_equal true, build_job.send(:check_and_handle_mcp_failure, @session, 12345, log_buffer),
      "an already-written-off REQUIRED server must not be waved through as old news"

    @session.reload
    # The ladder starts over on a restart, so this attempt retries rather than failing
    # outright — what matters is that it was not silently resumed with the tools gone.
    assert_equal "needs_input", @session.status
    assert_equal 1, @session.metadata["mcp_retry_count"]

    # And at the end of that ladder it is fatal again.
    @session.update!(
      status: :running,
      metadata: @session.metadata.merge("mcp_retry_count" => RetryBudget::MCP_CONNECTION.max)
    )
    build_job.send(:check_and_handle_mcp_failure, @session, 12345, LogBuffer.new(@session))
    assert_equal "failed", @session.reload.status
    assert_equal AgentSessionJob::REQUIRED_MCP_SERVER_LOST_FAILURE_REASON, @session.metadata["failure_reason"]
  end

  test "an already-degraded ORDINARY server is still waved through as old news" do
    # The short-circuit above is narrowed for required servers only — #521's
    # terminate-and-resume loop guard has to keep working for everything else.
    @session.update!(
      mcp_servers: [ "context7" ],
      metadata: (@session.metadata || {}).merge(
        "mcp_degraded_servers" => [ { "name" => "context7", "error" => "Connection closed" } ]
      )
    )
    flag_failure!("context7", error: "Connection closed")

    assert_equal false,
      build_job.send(:check_and_handle_mcp_failure, @session, 12345, LogBuffer.new(@session))

    @session.reload
    assert_equal "running", @session.status
    assert_nil @session.custom_metadata["should_fail_session"]
  end

  test "a non-required server exhausting the ladder still degrades and resumes" do
    # #521 unchanged. The carve-out is narrow on purpose: getting this wrong the
    # other way starts killing sessions over a server nobody ever called.
    @session.update!(mcp_servers: [ "context7" ])
    flag_failure!("context7", error: "Connection closed", retry_count: RetryBudget::MCP_CONNECTION.max)
    log_buffer = LogBuffer.new(@session)

    assert_equal true, build_job.send(:check_and_handle_mcp_failure, @session, 12345, log_buffer)

    @session.reload
    assert_not_equal "failed", @session.status
    assert_nil @session.metadata["failure_reason"]
    assert_equal [ "context7" ], @session.degraded_mcp_server_names
    assert_enqueued_with(job: AgentSessionJob)
  end

  test "a required server lost alongside an ordinary one fails the session and records both" do
    # One handshake, two verdicts. The session still cannot finish, so the required
    # loss decides what happens — but the other server's write-off is not thrown away.
    @session.update!(mcp_servers: [ "context7" ])
    @session.update!(
      metadata: (@session.metadata || {}).merge("mcp_retry_count" => RetryBudget::MCP_CONNECTION.max),
      custom_metadata: (@session.custom_metadata || {}).merge(
        "should_fail_session" => true,
        "mcp_failed_servers" => [
          { "name" => "context7", "status" => "failed", "error" => "Connection closed" },
          { "name" => ZIMMER_SELF_SESSION, "status" => "failed", "error" => "Connection failed after 94ms" }
        ],
        "mcp_failure_reason" => "MCP server(s) failed to connect"
      )
    )
    log_buffer = LogBuffer.new(@session)

    assert_equal true, build_job.send(:check_and_handle_mcp_failure, @session, 12345, log_buffer)

    @session.reload
    assert_equal "failed", @session.status
    assert_equal [ ZIMMER_SELF_SESSION ], @session.metadata[AgentSessionJob::REQUIRED_MCP_SERVERS_LOST_KEY]
    assert_equal [ "context7", ZIMMER_SELF_SESSION ].sort, @session.degraded_mcp_server_names.sort
  end

  # The failure must not latch: a session failed for a lost required server has to
  # be able to run again the moment the server is back. Two halves —
  # `clear_stale_mcp_failure_metadata` drops the verdict on the way back in (here),
  # and `McpStatusPersisting` retires the write-off when the server reports
  # `connected` (test/services/mcp_status_persisting_test.rb).
  test "the verdict does not survive the resume that follows it" do
    flag_failure!(
      ZIMMER_SELF_SESSION,
      error: "Connection failed after 94ms",
      retry_count: RetryBudget::MCP_CONNECTION.max
    )
    build_job.send(:check_and_handle_mcp_failure, @session, 12345, LogBuffer.new(@session))
    assert_equal "failed", @session.reload.status

    # What every restart and resume path does on the way back in.
    @session.remove_metadata!(Session::STALE_RETRY_METADATA_KEYS)
    @session.send(:clear_stale_mcp_failure_metadata)

    @session.reload
    assert_nil @session.metadata["failure_reason"],
      "a restart must not inherit the previous run's verdict"
    assert_nil @session.metadata[AgentSessionJob::REQUIRED_MCP_SERVERS_LOST_KEY]
    assert_nil @session.custom_metadata["should_fail_session"]
    assert_equal "pending", @session.custom_metadata.dig("mcp_servers_status", ZIMMER_SELF_SESSION, "status"),
      "the next run gets to reach its own verdict about the server"
  end

  # The two halves of the fix meet here: the detector's verdict has to escalate
  # (McpStatusPersisting) AND the escalation has to fail the session
  # (check_and_handle_mcp_failure). Either half alone leaves the silent no-op in
  # place, so one test drives the real detector object through both.
  test "a detected failure of the self-session server fails the session, end to end" do
    @session.update!(metadata: (@session.metadata || {}).merge(
      "mcp_retry_count" => RetryBudget::MCP_CONNECTION.max
    ))
    detector = McpLogPollerService.new(@session)

    escalated = detector.update_session_mcp_status(
      ZIMMER_SELF_SESSION => { status: "failed", error: "Connection failed after 94ms (500)" }
    )

    assert escalated, "the detector's verdict must reach the job"
    assert @session.reload.custom_metadata["should_fail_session"]

    build_job.send(:check_and_handle_mcp_failure, @session, 12345, LogBuffer.new(@session))

    @session.reload
    assert_equal "failed", @session.status
    assert_equal AgentSessionJob::REQUIRED_MCP_SERVER_LOST_FAILURE_REASON, @session.metadata["failure_reason"]
  end

  test "the metadata key the job writes is one a restart clears" do
    assert_includes Session::STALE_RETRY_METADATA_KEYS, AgentSessionJob::REQUIRED_MCP_SERVERS_LOST_KEY
  end
end
