# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class TriggerConditionMcpEventTest < ActiveSupport::TestCase
  include McpEventCatalogHelper

  setup do
    stub_events_catalog_server("http://127.0.0.1:9/mcp?servers=slack-zimmer")
  end

  def build_trigger(configuration, template: "{{event_id}} {{event.text|untrusted}}")
    Trigger.new(
      name: "events", status: "enabled", agent_root_name: "zimmer", prompt_template: template,
      trigger_conditions_attributes: [ { condition_type: "mcp_event", configuration: configuration } ]
    )
  end

  def valid_config(extra = {})
    { "server" => "slack-zimmer", "event_name" => "slack-zimmer__message_posted" }.merge(extra)
  end

  test "server and event_name are required, and the server must be a remote catalog server" do
    assert build_trigger(valid_config).valid?

    trigger = build_trigger({ "event_name" => "x" })
    assert_not trigger.valid?
    assert_match(/must include server/, trigger.trigger_conditions.first.errors.full_messages.join)

    trigger = build_trigger(valid_config("server" => "no-such-server"))
    assert_not trigger.valid?
    assert_match(/not in the MCP server catalog/, trigger.trigger_conditions.first.errors.full_messages.join)

    stdio = ServersConfig.all.find { |server| server.type == "stdio" }
    trigger = build_trigger(valid_config("server" => stdio.name))
    assert_not trigger.valid?
    assert_match(/remote one/, trigger.trigger_conditions.first.errors.full_messages.join)

    trigger = build_trigger(valid_config("event_name" => "has spaces"))
    assert_not trigger.valid?
  end

  test "arguments and payload_filters arrive as JSON text from the form and are stored as objects" do
    trigger = build_trigger(valid_config("arguments" => '{"addressed_to_bot": true}', "payload_filters" => '{"user_id": "U1"}'))
    assert trigger.valid?, trigger.errors.full_messages.inspect
    condition = trigger.trigger_conditions.first
    assert_equal({ "addressed_to_bot" => true }, condition.mcp_event_arguments)
    assert_equal({ "user_id" => [ "U1" ] }, condition.mcp_event_payload_filters)

    bad = build_trigger(valid_config("arguments" => "{not json"))
    assert_not bad.valid?
    assert_match(/arguments is not valid JSON/, bad.trigger_conditions.first.errors.full_messages.join)

    blank = build_trigger(valid_config("arguments" => "  "))
    assert blank.valid?
    assert_not blank.trigger_conditions.first.configuration.key?("arguments")
  end

  test "payload filters must name fields and allow at least one scalar value" do
    assert_not build_trigger(valid_config("payload_filters" => { "not a field" => [ "x" ] })).valid?
    assert_not build_trigger(valid_config("payload_filters" => { "user_id" => [] })).valid?
    assert_not build_trigger(valid_config("payload_filters" => { "user_id" => [ { "id" => "U1" } ] })).valid?
  end

  test "a workflow trigger cannot carry an mcp_event condition" do
    trigger = build_trigger(valid_config)
    trigger.workflow_id = "anything"
    assert_not trigger.valid?
    assert_match(/cannot be combined with an MCP event condition/, trigger.errors.full_messages.join)
  end

  test "|id renders only a string or number in an identifier's shape" do
    trigger = build_trigger(valid_config, template: "[{{event.a|id}}][{{event.b|id}}][{{event.c|id}}][{{event.d|id}}]")
    rendered = trigger.interpolate_prompt(event_data: { "a" => "C0123", "b" => true, "c" => nil, "d" => 1793.5 })
    assert_equal "[C0123][][][1793.5]", rendered
  end

  test "payload filters fail closed on a field the payload does not carry" do
    condition = TriggerCondition.new(condition_type: "mcp_event", configuration: valid_config("payload_filters" => { "user_id" => [ "U1" ] }))
    assert condition.mcp_event_payload_allowed?({ "user_id" => "U1" })
    assert_not condition.mcp_event_payload_allowed?({ "user_id" => "U2" })
    assert_not condition.mcp_event_payload_allowed?({})
    assert_not condition.mcp_event_payload_allowed?({ "user_id" => [ "U1" ] })
  end

  test "a bare payload field in the template is refused; |untrusted and |id are fine" do
    assert build_trigger(valid_config, template: "{{event.channel_id|id}} {{event.text|untrusted}} {{event_id}}").valid?

    trigger = build_trigger(valid_config, template: "Do this: {{event.text}}")
    assert_not trigger.valid?
    assert_match(/\{\{event\.text\|untrusted\}\}/, trigger.errors[:prompt_template].join)
  end

  test "poll state survives an edit that omits it, and a subscription change drops it" do
    trigger = build_trigger(valid_config)
    trigger.save!
    condition = trigger.trigger_conditions.first
    condition.update!(configuration: condition.configuration.merge("cursor" => "seq:9", "failures" => 2))

    condition.update!(configuration: valid_config("payload_filters" => { "user_id" => [ "U1" ] }))
    assert_equal "seq:9", condition.reload.mcp_event_cursor

    condition.update!(configuration: valid_config("arguments" => { "addressed_to_bot" => true }))
    assert_nil condition.reload.mcp_event_cursor
    assert_nil condition.configuration["failures"]
  end

  test "describes itself" do
    condition = TriggerCondition.new(condition_type: "mcp_event", configuration: valid_config("payload_filters" => { "user_id" => [ "U1" ] }))
    assert_equal "MCP Event: slack-zimmer__message_posted from slack-zimmer, filtered on user_id", condition.description
  end
end
