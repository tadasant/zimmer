# frozen_string_literal: true

require "test_helper"

# `include=board_row` on the listings: what a dashboard row shows that the
# `session` object does not carry — the agent root and the status summary.
class Api::V1::SessionsBoardRowsTest < ActionDispatch::IntegrationTest
  setup do
    @headers = { "X-API-Key" => "test_api_key_board_rows" }
    ENV["API_KEYS"] = "test_api_key_board_rows"
    Session.delete_all
    @root = AgentRootsConfig.all.first
    @summarised = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", title: "summarised", status: :needs_input)
    @summarised.update_columns(metadata: @summarised.metadata.merge("agent_root_key" => @root.name))
    SessionStatusSummary.create!(
      session: @summarised, state: "ready", generated_at: Time.current,
      transcript_line_count: @summarised.transcript_line_count,
      summary: "The PR is [open](https://github.com/t/r/pull/1)."
    )
    @bare = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", title: "bare", status: :needs_input)
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  def rows(path, params)
    get path, params: params, headers: @headers
    assert_response :success, response.body
    JSON.parse(response.body)["board_rows"]
  end

  test "the listing carries each row's agent root and status summary when asked" do
    board = rows("/api/v1/sessions", include: "board_row")

    row = board.fetch(@summarised.id.to_s)
    assert_equal @root.name, row["agent_root"]
    assert_equal "The PR is [open](https://github.com/t/r/pull/1).", row.dig("status_summary", "summary")
    assert_equal 0, row.dig("status_summary", "messages_since_generated")
    assert_nil board.fetch(@bare.id.to_s)["status_summary"]
  end

  test "the user view and search carry them too" do
    assert_includes rows("/api/v1/sessions", include: "board_row", view: "user").keys, @summarised.id.to_s
    assert_includes rows("/api/v1/sessions/search", include: "board_row", q: "summarised").keys, @summarised.id.to_s
    assert_includes rows("/api/v1/sessions", include: %w[board_row]).keys, @summarised.id.to_s
  end

  test "nothing is added unless asked" do
    get "/api/v1/sessions", headers: @headers
    assert_response :success
    assert_not JSON.parse(response.body).key?("board_rows")
    assert_nil rows("/api/v1/sessions", include: "something_else")
  end

  test "the summaries are read in one query for the page" do
    3.times do |i|
      session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", title: "more #{i}", status: :needs_input)
      SessionStatusSummary.create!(session: session, state: "ready", generated_at: Time.current, transcript_line_count: 0, summary: "s#{i}")
    end
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?("session_status_summaries") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      rows("/api/v1/sessions", include: "board_row")
    end
    assert_equal 1, queries.size, queries.join("\n")
  end
end
