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

  test "lines up an email condition's gmail claims with a Gmail MCP event's" do
    email = Trigger.create!(
      name: "Zimmer inbox", status: "enabled", agent_root_name: "zimmer", prompt_template: "{{message_id}} {{text|untrusted}}",
      trigger_conditions_attributes: [ { condition_type: "email", configuration: { "query" => "in:inbox" } } ]
    )
    # One email fire covers a thread's two new messages; the MCP shadow fires once per message. The
    # server segment of the shadow's key is stripped whatever it names, so the fixture's slug serves.
    claim(email, "gmail:18c0a1", at: 1.hour.ago, via: "email_record")
    claim(email, "gmail:18c0a2", at: 1.hour.ago, via: "email_record")
    claim(@shadow, "mcp:slack-zimmer:gmail:18c0a1", at: 1.hour.ago + 30.seconds, via: "mcp_event")
    claim(@shadow, "mcp:slack-zimmer:gmail:18c0a2", at: 1.hour.ago + 31.seconds, via: "mcp_event")
    # Mail the email condition skipped (automated, or dropped by burst control) records nothing.
    claim(@shadow, "mcp:slack-zimmer:gmail:18c0b9", at: 1.hour.ago, via: "mcp_event")

    result = @tool.call("trigger_a_id" => email.id, "trigger_b_id" => @shadow.id)

    assert_equal({ matched: 2, only_a: 0, only_b: 1, pending: 0 }, result[:counts])
    assert_equal %w[gmail:18c0a1 gmail:18c0a2], result[:recent].select { |row| row[:status] == "matched" }.map { |row| row[:event] }.sort
    assert_equal "gmail:18c0b9", result[:recent].find { |row| row[:status] == "only_b" }[:event]
  end

  test "lines up a WhatsApp condition's claims with a WhatsApp MCP event's" do
    chat = "120363000000000001@g.us"
    whatsapp = Trigger.create!(
      name: "Group chat", status: "enabled", agent_root_name: "zimmer", prompt_template: "{{chat_id}} {{text|untrusted}}",
      trigger_conditions_attributes: [ { condition_type: "whatsapp", configuration: { "chat_id" => chat, "mode" => "listen" } } ]
    )
    # One WhatsApp fire covers a minute's batch of two messages; the MCP shadow fires once per
    # message. The server segment of the shadow's key is stripped whatever it names.
    claim(whatsapp, "whatsapp:#{chat}:3EB0AA01", at: 1.hour.ago, via: "whatsapp_record")
    claim(whatsapp, "whatsapp:#{chat}:3EB0AA02", at: 1.hour.ago, via: "whatsapp_record")
    claim(@shadow, "mcp:slack-zimmer:whatsapp:#{chat}:3EB0AA01", at: 1.hour.ago + 30.seconds, via: "mcp_event")
    claim(@shadow, "mcp:slack-zimmer:whatsapp:#{chat}:3EB0AA02", at: 1.hour.ago + 31.seconds, via: "mcp_event")
    # A message id is unique within its chat only: the same id in another chat is another event.
    claim(@shadow, "mcp:slack-zimmer:whatsapp:15550001111@s.whatsapp.net:3EB0AA01", at: 1.hour.ago, via: "mcp_event")

    result = @tool.call("trigger_a_id" => whatsapp.id, "trigger_b_id" => @shadow.id)

    assert_equal({ matched: 2, only_a: 0, only_b: 1, pending: 0 }, result[:counts])
    assert_equal [ "whatsapp:#{chat}:3EB0AA01", "whatsapp:#{chat}:3EB0AA02" ],
                 result[:recent].select { |row| row[:status] == "matched" }.map { |row| row[:event] }.sort
    assert_equal "whatsapp:15550001111@s.whatsapp.net:3EB0AA01", result[:recent].find { |row| row[:status] == "only_b" }[:event]
  end

  test "since bounds the comparison" do
    claim(@original, "slack:C1:1.000001", at: 2.days.ago, via: "poll")
    result = @tool.call("trigger_a_id" => @original.id, "trigger_b_id" => @shadow.id, "since" => 1.day.ago.iso8601)
    assert_equal 0, result[:counts].values.sum
  end

  test "a restricted connection cannot compare a trigger on a root it may not use" do
    tool = Mcp::Tools::CompareTriggerFires.new(context: Mcp::Context.new(allowed_agent_roots: [ "some-other-root" ]))
    error = assert_raises(Mcp::ToolError) { tool.call("trigger_a_id" => @original.id, "trigger_b_id" => @shadow.id) }
    assert_match(/not found/, error.message)
  end

  test "an unknown trigger is a tool error" do
    assert_raises(Mcp::ToolError) { @tool.call("trigger_a_id" => 0, "trigger_b_id" => @shadow.id) }
  end
end
