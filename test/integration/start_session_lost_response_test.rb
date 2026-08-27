# frozen_string_literal: true

require "test_helper"

# The lost-response failure from #577, driven end to end over the two surfaces
# that create a session: `start_session` on POST /mcp, and POST /api/v1/sessions.
#
# The failure cannot be reproduced by making a request time out — the timeout is
# not the bug. The bug is what the caller is left holding: the create COMMITTED,
# and the response carrying its id never arrived, so "retry" and "the write never
# happened" look identical from the outside. That is reproduced exactly by
# issuing the create, throwing the response away, and issuing it again — which is
# what a caller that saw the proxy's HTML 504 does.
#
# Each pair of tests below is the before and after of that: without a key the
# retry duplicates the session (still true, and asserted so the cost of omitting
# a key is visible), with one it does not.
class StartSessionLostResponseTest < ActionDispatch::IntegrationTest
  setup do
    @api_key = "test_api_key_12345"
    ENV["API_KEYS"] = @api_key
    @headers = {
      "X-API-Key" => @api_key,
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream"
    }
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # --- POST /mcp → start_session ---

  test "MCP: a retry after a lost response duplicates the session when no idempotency_key was sent" do
    args = spawn_args

    assert_difference "Session.count", 2 do
      start_session(args)
      # The caller sees the proxy's HTML 504 instead of this result and retries.
      start_session(args)
    end

    titled = Session.where(title: args["title"]).order(:id)
    assert_equal 2, titled.count, "two sessions for one unit of work is the defect"
    refute_equal titled.first.id, titled.last.id
  end

  test "MCP: a retry with the same idempotency_key returns the first session and creates no second one" do
    args = spawn_args.merge("idempotency_key" => "issue-577-lost-response")

    assert_difference "Session.count", 1 do
      @first = text_of(start_session(args))
      @second = text_of(start_session(args))
    end

    session = Session.find_by!(idempotency_key: "issue-577-lost-response")
    assert_equal 1, Session.where(title: args["title"]).count

    assert_includes @first, "## Session Started Successfully"
    assert_includes @second, "## Existing Session Returned (idempotency_key matched)"
    assert_includes @second, "- **ID:** #{session.id}", "the retry has to hand back the id the lost response carried"
    assert_includes @second, "no new session was created"
  end

  test "MCP: the retry queues no second agent job" do
    args = spawn_args.merge("idempotency_key" => "issue-577-one-job")

    start_session(args)
    before = enqueued_agent_jobs

    start_session(args)

    assert_equal before, enqueued_agent_jobs,
                 "a replayed create must not queue a second agent — that is the clone and the quota slot"
  end

  test "MCP: a fresh key after a replay still creates a new session" do
    start_session(spawn_args.merge("idempotency_key" => "issue-577-first"))

    assert_difference "Session.count", 1 do
      start_session(spawn_args.merge("idempotency_key" => "issue-577-second"))
    end
  end

  test "MCP: the tool advertises idempotency_key and tells a caller what to do on a timeout" do
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }.to_json, headers: @headers
    tool = JSON.parse(response.body)["result"]["tools"].find { |t| t["name"] == "start_session" }

    assert tool["inputSchema"]["properties"].key?("idempotency_key")
    assert_match(/idempotency_key/, tool["description"])
    assert_match(/quick_search_sessions/, tool["description"],
                 "a caller without a key needs the search-first workaround in the contract it reads")
  end

  # --- POST /api/v1/sessions ---

  test "REST: a retry after a lost response duplicates the session when no idempotency_key was sent" do
    assert_difference "Session.count", 2 do
      post "/api/v1/sessions", params: rest_args.to_json, headers: @headers
      assert_response :created
      post "/api/v1/sessions", params: rest_args.to_json, headers: @headers
      assert_response :created
    end
  end

  test "REST: a retry with the same idempotency_key replays the first session with 200" do
    body = rest_args.merge(idempotency_key: "issue-577-rest")

    assert_difference "Session.count", 1 do
      post "/api/v1/sessions", params: body.to_json, headers: @headers
      assert_response :created
      @created_id = JSON.parse(response.body)["session"]["id"]

      post "/api/v1/sessions", params: body.to_json, headers: @headers
      assert_response :ok
    end

    replay = JSON.parse(response.body)
    assert_equal true, replay["idempotent_replay"]
    assert_equal @created_id, replay["session"]["id"]
  end

  private

  def spawn_args
    {
      "agent_root" => "zimmer",
      "prompt" => "Fix the lost-response hole",
      "title" => "Fix the lost-response hole"
    }
  end

  def rest_args
    {
      agent_root: "zimmer",
      prompt: "Fix the lost-response hole",
      title: "Fix the lost-response hole"
    }
  end

  def start_session(arguments)
    post "/mcp",
      params: { jsonrpc: "2.0", id: 1, method: "tools/call",
                params: { "name" => "start_session", "arguments" => arguments } }.to_json,
      headers: @headers
    assert_response :success
    JSON.parse(response.body)
  end

  def text_of(body)
    refute body["result"]["isError"], "tool call errored: #{body.inspect}"
    body["result"]["content"].first["text"]
  end

  def enqueued_agent_jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == AgentSessionJob }
  end
end
