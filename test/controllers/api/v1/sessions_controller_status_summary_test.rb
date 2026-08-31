# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The Status blurb on the REST surface: a sibling of `session` on show, a forced
# async regenerate endpoint, and summary forks kept out of the index.
class Api::V1::SessionsControllerStatusSummaryTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)

    @api_key = "test_api_key_12345"
    ENV["API_KEYS"] = @api_key
    @headers = { "X-API-Key" => @api_key }

    # A real directory: regeneration is refused when there is no clone left to
    # fork — see SessionStatusSummaryGenerator.unavailable_reason.
    @clone_path = Dir.mktmpdir("status-summary-clone")

    @session = Session.create!(
      prompt: "Ship the thing",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      metadata: { "clone_path" => @clone_path },
      transcript: "{}\n{}\n{}\n{}\n"
    )
  end

  teardown do
    FileUtils.remove_entry(@clone_path) if @clone_path && File.directory?(@clone_path)
    ENV.delete("API_KEYS")
    Mocha::Mockery.instance.teardown
  end

  test "show carries a null status_summary when none has been generated" do
    get "/api/v1/sessions/#{@session.id}", headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert json.key?("status_summary"), "status_summary must always be present on show"
    assert_nil json["status_summary"]
  end

  # A caller that asked for a regeneration must be able to tell "still running"
  # from "never generated" without polling for text that may never arrive.
  test "show reports an in-flight generation before any text exists" do
    SessionStatusSummary.create!(session: @session, state: "pending", requested_at: 1.minute.ago)

    get "/api/v1/sessions/#{@session.id}", headers: @headers

    assert_response :success
    summary = JSON.parse(response.body)["status_summary"]
    assert_nil summary["summary"]
    assert_equal "pending", summary["state"]
    assert summary["generating"]
  end

  test "show reports a failure reason when the last attempt failed" do
    SessionStatusSummary.create!(session: @session, state: "failed", error: "Source clone directory does not exist")

    get "/api/v1/sessions/#{@session.id}", headers: @headers

    assert_response :success
    summary = JSON.parse(response.body)["status_summary"]
    assert_equal "failed", summary["state"]
    assert_equal "Source clone directory does not exist", summary["error"]
    assert_not summary["generating"]
  end

  test "show carries the summary and how far behind it is" do
    SessionStatusSummary.create!(
      session: @session, state: "ready", generated_at: Time.current,
      transcript_line_count: 1, summary: "The PR is open."
    )

    get "/api/v1/sessions/#{@session.id}", headers: @headers

    assert_response :success
    summary = JSON.parse(response.body)["status_summary"]
    assert_equal "The PR is open.", summary["summary"]
    assert_equal 3, summary["messages_since_generated"]
    assert_equal "ready", summary["state"]
  end

  test "regenerate_status_summary queues a forced generation" do
    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ @session.id, { force: true } ]) do
      post "/api/v1/sessions/#{@session.id}/regenerate_status_summary", headers: @headers
    end

    assert_response :accepted
    assert_equal "Status summary regeneration queued", JSON.parse(response.body)["message"]
  end

  # The same rule the Status panel's button follows: archived is not a reason to
  # refuse, a reclaimed clone is.
  test "regenerate_status_summary accepts an archived session that still has its clone" do
    @session.update_column(:status, Session.statuses[:archived])

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ @session.id, { force: true } ]) do
      post "/api/v1/sessions/#{@session.id}/regenerate_status_summary", headers: @headers
    end

    assert_response :accepted
  end

  test "regenerate_status_summary accepts an archived session whose clone is gone" do
    @session.update_column(:status, Session.statuses[:archived])
    FileUtils.remove_entry(@clone_path)

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ @session.id, { force: true } ]) do
      post "/api/v1/sessions/#{@session.id}/regenerate_status_summary", headers: @headers
    end

    assert_response :accepted
  end

  # 422 covers the refusals that remain — a caller must not read 202 for a
  # session that has nothing to summarize at all.
  test "regenerate_status_summary refuses a session with no transcript" do
    @session.update_column(:transcript, nil)

    assert_no_enqueued_jobs(only: SessionStatusSummaryJob) do
      post "/api/v1/sessions/#{@session.id}/regenerate_status_summary", headers: @headers
    end

    assert_response :unprocessable_entity
    assert_match "no conversation", response.body
  end

  test "get_session's text-less states are distinguishable over MCP too" do
    SessionStatusSummary.create!(session: @session, state: "pending", requested_at: 1.minute.ago)

    output = Mcp::Tools::GetSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
      .call("id" => @session.id)

    assert_includes output, "A summary is being generated now"
  end

  test "the index does not list Zimmer's own summary forks" do
    fork = Session.create!(
      prompt: "summarize",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      metadata: { SessionStatusSummaryGenerator::FORK_MARKER => @session.id }
    )

    get "/api/v1/sessions", headers: @headers, params: { per_page: 100 }

    assert_response :success
    ids = JSON.parse(response.body)["sessions"].map { |s| s["id"] }
    assert_includes ids, @session.id
    assert_not_includes ids, fork.id
  end
end
