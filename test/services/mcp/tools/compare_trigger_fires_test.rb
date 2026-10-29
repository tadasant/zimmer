# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Mcp::Tools::CompareTriggerFiresTest < ActiveSupport::TestCase
  include McpEventCatalogHelper

  setup do
    stub_events_catalog_server("http://127.0.0.1:9/mcp?servers=slack-zimmer")
    @original = Trigger.create!(
      name: "Slack mentions", status: "enabled", agent_root_name: "zimmer", prompt_template: "{{link}}",
      trigger_conditions_attributes: [ { condition_type: "slack", configuration: { "event_type" => "bot_mention" } } ]
    )
    @shadow = Trigger.create!(
      name: "Slack mentions via MCP events", status: "enabled", agent_root_name: "zimmer", prompt_template: "{{event_id}}",
      trigger_conditions_attributes: [ { condition_type: "mcp_event",
                                         configuration: { "server" => "slack-zimmer", "event_name" => "slack-zimmer__message_posted" } } ]
    )
    @tool = Mcp::Tools::CompareTriggerFires.new(context: Mcp::Context.new)
  end

  def claim(trigger, key, at:, via:)
    TriggerEventClaim.create!(trigger_condition: trigger.trigger_conditions.first, event_key: key, claimed_via: via, created_at: at)
  end

  test "lines up a Slack claim with the MCP event claim for the same message" do
    claim(@original, "slack:C1:1.000001", at: 1.hour.ago, via: "poll")
    claim(@shadow, "mcp:slack-zimmer:slack:C1:1.000001", at: 1.hour.ago + 20.seconds, via: "mcp_event")
    claim(@original, "slack:C1:2.000001", at: 1.hour.ago, via: "poll")
    claim(@shadow, "mcp:slack-zimmer:slack:C1:3.000001", at: 1.hour.ago, via: "mcp_event")
    claim(@original, "slack:C1:4.000001", at: 1.minute.ago, via: "poll")

    result = @tool.call("trigger_a_id" => @original.id, "trigger_b_id" => @shadow.id)

    assert_equal({ matched: 1, only_a: 1, only_b: 1, pending: 1 }, result[:counts])
    matched = result[:recent].find { |row| row[:status] == "matched" }
    assert_equal "slack:C1:1.000001", matched[:event]
    assert_equal 20, matched[:seconds_apart]
  end

  test "since bounds the comparison" do
    claim(@original, "slack:C1:1.000001", at: 2.days.ago, via: "poll")
    result = @tool.call("trigger_a_id" => @original.id, "trigger_b_id" => @shadow.id, "since" => 1.day.ago.iso8601)
    assert_equal 0, result[:counts].values.sum
  end

  test "an unknown trigger is a tool error" do
    assert_raises(Mcp::ToolError) { @tool.call("trigger_a_id" => 0, "trigger_b_id" => @shadow.id) }
  end
end
