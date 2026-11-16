# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::CompareGithubWebhookShadowTest < ActiveSupport::TestCase
  setup do
    @condition = trigger_conditions(:github_issue_condition)
    @saved = ENV["GITHUB_TRIGGER_INGEST_MODE"]
    ENV["GITHUB_TRIGGER_INGEST_MODE"] = "webhook_shadow"
    @tool = Mcp::Tools::CompareGithubWebhookShadow.new(context: Mcp::Context.new)
  end

  teardown { @saved.nil? ? ENV.delete("GITHUB_TRIGGER_INGEST_MODE") : ENV["GITHUB_TRIGGER_INGEST_MODE"] = @saved }

  def observe(key, path, at)
    TriggerShadowObservation.record!(@condition, key, path: path, delivery_id: (path == "webhook" ? SecureRandom.uuid : nil), now: at)
  end

  test "reports the shadow comparison with the mode, totals, a row per condition and the events" do
    observe("github:tadasant/zimmer#1:opened", "webhook", 2.hours.ago)
    observe("github:tadasant/zimmer#1:opened", "poll", 2.hours.ago + 45.seconds)
    observe("github:tadasant/zimmer#2:opened", "poll", 3.hours.ago)

    result = @tool.call({})

    assert_equal "webhook_shadow", result[:mode]
    assert_equal({ matched: 1, webhook_only: 0, poll_only: 1, pending: 0 }, result[:totals])
    assert_equal 45, result[:latency][:median_seconds]
    assert_equal [ @condition.id ], result[:conditions].map { |row| row[:condition_id] }
    assert_equal 45, result[:recent].find { |e| e[:status] == "matched" }[:webhook_lead_seconds]
    assert_kind_of String, result[:since]
  end

  test "takes a window, a grace, a condition and a limit" do
    observe("github:tadasant/zimmer#1:opened", "webhook", 3.days.ago)
    observe("github:tadasant/zimmer#2:opened", "webhook", 10.minutes.ago)

    result = @tool.call("since" => 4.days.ago.iso8601, "grace_minutes" => 5, "condition_id" => @condition.id, "limit" => 1)

    assert_equal({ matched: 0, webhook_only: 2, poll_only: 0, pending: 0 }, result[:totals])
    assert_equal 300, result[:grace_seconds]
    assert_equal 1, result[:recent].size
    assert_empty @tool.call("condition_id" => @condition.id + 10_000)[:conditions]
  end

  test "a restricted connection sees only conditions on its roots" do
    observe("github:tadasant/zimmer#1:opened", "webhook", 1.hour.ago)
    tool = Mcp::Tools::CompareGithubWebhookShadow.new(context: Mcp::Context.new(allowed_agent_roots: [ "some-other-root" ]))

    assert_empty tool.call({})[:conditions]
  end

  test "a malformed since is a tool error" do
    assert_raises(Mcp::ToolError) { @tool.call("since" => "yesterday") }
  end
end
