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

    @session = Session.create!(
      prompt: "Ship the thing",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: "{}\n{}\n{}\n{}\n"
    )
  end

  teardown do
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
