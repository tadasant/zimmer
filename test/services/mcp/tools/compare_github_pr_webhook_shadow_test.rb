# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::CompareGithubPrWebhookShadowTest < ActiveSupport::TestCase
  PR = "https://github.com/tadasant/zimmer/pull/7"

  setup do
    @saved = ENV["GITHUB_PR_INGEST_MODE"]
    ENV["GITHUB_PR_INGEST_MODE"] = "webhook_shadow"
    @session = sessions(:running)
    @tool = Mcp::Tools::CompareGithubPrWebhookShadow.new(context: Mcp::Context.new)
  end

  teardown { @saved.nil? ? ENV.delete("GITHUB_PR_INGEST_MODE") : ENV["GITHUB_PR_INGEST_MODE"] = @saved }

  def observe(kind, at, lead: nil, mode: "webhook_shadow", session: @session)
    GithubPrShadowObservation.record!(
      session_id: session.id, pr_url: PR, kind: kind, mode: mode, signaled_at: lead && at - lead, now: at
    )
  end

  test "reports hits, misses and lead per kind, with the newest misses" do
    observe("status", 2.hours.ago, lead: 20.seconds)
    observe("status", 90.minutes.ago, lead: 40.seconds)
    observe("comments", 1.hour.ago, lead: 70.seconds)
    observe("comments", 30.minutes.ago)
    observe("merge_conflict", 3.days.ago)

    result = @tool.call({})

    assert_equal "webhook_shadow", result[:mode]
    assert_equal({ hit: 3, miss: 1, hit_rate: 0.75 }, result[:totals])
    assert_equal({ samples: 3, median_seconds: 40, p90_seconds: 70, max_seconds: 70 }, result[:lead])
    status = result[:kinds].find { |row| row[:kind] == "status" }
    assert_equal [ 2, 0, 1.0 ], status.values_at(:hit, :miss, :hit_rate)
    assert_equal %w[status ci comments merge_conflict], result[:kinds].map { |row| row[:kind] }
    assert_nil result[:kinds].find { |row| row[:kind] == "ci" }[:hit_rate]
    assert_equal({ "webhook_shadow" => 4 }, result[:modes])
    assert_equal [ [ "comments", PR, @session.id ] ], result[:recent_misses].map { |row| row.values_at(:kind, :pr_url, :session_id) }
    assert_kind_of String, result[:since]
  end

  test "takes a window, a kind, a mode and a limit" do
    observe("merge_conflict", 3.days.ago)
    observe("merge_conflict", 2.days.ago)
    observe("merge_conflict", 1.hour.ago, mode: "webhook_with_poll_fallback")
    observe("status", 1.hour.ago)

    result = @tool.call("since" => 4.days.ago.iso8601, "kind" => "merge_conflict", "mode" => "webhook_shadow", "limit" => 1)

    assert_equal({ hit: 0, miss: 2, hit_rate: 0.0 }, result[:totals])
    assert_equal %w[merge_conflict], result[:kinds].map { |row| row[:kind] }
    assert_equal 1, result[:recent_misses].size
  end

  test "a restricted connection sees only sessions on its roots" do
    observe("status", 1.hour.ago)
    tool = Mcp::Tools::CompareGithubPrWebhookShadow.new(context: Mcp::Context.new(allowed_agent_roots: [ "some-other-root" ]))
    assert_equal 0, tool.call({})[:totals][:miss]

    @session.update_columns(metadata: (@session.metadata || {}).merge("agent_root_key" => "some-other-root"))
    assert_equal 1, tool.call({})[:totals][:miss]
  end

  test "a malformed since or an unknown kind is a tool error" do
    assert_raises(Mcp::ToolError) { @tool.call("since" => "yesterday") }
    assert_raises(Mcp::ToolError) { @tool.call("kind" => "labels") }
  end
end
