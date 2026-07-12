# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::ActionTriggerTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::ActionTrigger.new(context: Mcp::Context.new(tool_groups: "triggers"))
  end

  def restricted_tool(roots = "zimmer")
    Mcp::Tools::ActionTrigger.new(context: Mcp::Context.new(tool_groups: "triggers", allowed_agent_roots: roots))
  end

  test "creates a slack trigger" do
    output = @tool.call(
      "action" => "create",
      "name" => "Deploy Watcher",
      "trigger_type" => "slack",
      "agent_root_name" => "zimmer",
      "prompt_template" => "New message: {{link}}",
      "mcp_servers" => [ "slack-workspace" ],
      "configuration" => { "channel_id" => "C123", "channel_name" => "deploys" }
    )

    trigger = Trigger.find_by!(name: "Deploy Watcher")
    assert_equal "enabled", trigger.status
    assert_equal [ "slack-workspace" ], trigger.mcp_servers
    assert_equal "C123", trigger.trigger_conditions.sole.channel_id
    assert_includes output, "## Trigger Created"
    assert_includes output, "- **ID:** #{trigger.id}"
    assert_includes output, "- **Conditions:** slack"
    assert_includes output, "- **Agent Root:** zimmer"
  end

  test "creates a one-time schedule trigger" do
    @tool.call(
      "action" => "create",
      "name" => "One Shot",
      "trigger_type" => "schedule",
      "agent_root_name" => "zimmer",
      "prompt_template" => "Do the thing",
      "configuration" => { "scheduled_at" => "2030-01-01T09:00:00", "timezone" => "UTC" }
    )

    condition = Trigger.find_by!(name: "One Shot").trigger_conditions.sole
    assert_equal "schedule", condition.condition_type
    assert condition.one_time_schedule?
  end

  test "create requires the core fields" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "create", "name" => "Incomplete")
    end

    assert_match(/are required for the "create" action/, error.message)
  end

  test "create surfaces model validation failures" do
    assert_raises(ActiveRecord::RecordInvalid) do
      @tool.call(
        "action" => "create",
        "name" => "Bad Slack",
        "trigger_type" => "slack",
        "agent_root_name" => "zimmer",
        "prompt_template" => "hi",
        "configuration" => {}
      )
    end
  end

  test "create is blocked for an agent root outside the allow list" do
    error = assert_raises(Mcp::ToolError) do
      restricted_tool("pulsemcp").call(
        "action" => "create",
        "name" => "Not Allowed",
        "trigger_type" => "schedule",
        "agent_root_name" => "zimmer",
        "prompt_template" => "hi",
        "configuration" => { "interval" => 2, "unit" => "hours" }
      )
    end

    assert_match(/not permitted/, error.message)
    assert_nil Trigger.find_by(name: "Not Allowed")
  end

  test "create is allowed for an agent root inside the allow list" do
    restricted_tool.call(
      "action" => "create",
      "name" => "Allowed",
      "trigger_type" => "schedule",
      "agent_root_name" => "zimmer",
      "prompt_template" => "hi",
      "configuration" => { "interval" => 2, "unit" => "hours" }
    )

    assert Trigger.exists?(name: "Allowed")
  end

  test "updates the existing condition in place" do
    trigger = triggers(:enabled_slack_trigger)

    output = @tool.call(
      "action" => "update",
      "id" => trigger.id,
      "name" => "Renamed Handler",
      "configuration" => { "channel_id" => "C999", "channel_name" => "eng-alerts" }
    )

    trigger.reload
    assert_equal "Renamed Handler", trigger.name
    assert_equal 1, trigger.trigger_conditions.count
    assert_equal "C999", trigger.trigger_conditions.sole.channel_id
    assert_includes output, "## Trigger Updated"
    assert_includes output, "- **Status:** enabled"
  end

  test "update leaves mcp servers alone when the key is omitted" do
    trigger = triggers(:enabled_slack_trigger)

    @tool.call("action" => "update", "id" => trigger.id, "status" => "disabled")

    trigger.reload
    assert_equal [ "slack-workspace" ], trigger.mcp_servers
    assert_equal "disabled", trigger.status
  end

  test "update rejects a configuration change it cannot attach to a condition" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call(
        "action" => "update",
        "id" => triggers(:multi_condition_trigger).id,
        "configuration" => { "interval" => 5, "unit" => "minutes" }
      )
    end

    assert_match(/without a trigger_type/, error.message)
  end

  test "update is blocked when the trigger's agent root is outside the allow list" do
    error = assert_raises(Mcp::ToolError) do
      restricted_tool("pulsemcp").call(
        "action" => "update",
        "id" => triggers(:enabled_slack_trigger).id,
        "name" => "Hijacked"
      )
    end

    assert_match(/not permitted/, error.message)
    assert_equal "CI Failure Handler", triggers(:enabled_slack_trigger).reload.name
  end

  test "deletes a trigger" do
    trigger = triggers(:new_slack_trigger)

    output = @tool.call("action" => "delete", "id" => trigger.id)

    assert_not Trigger.exists?(trigger.id)
    assert_includes output, "Trigger #{trigger.id} has been deleted."
  end

  test "toggles a trigger" do
    trigger = triggers(:enabled_slack_trigger)

    output = @tool.call("action" => "toggle", "id" => trigger.id)

    assert_equal "disabled", trigger.reload.status
    assert_includes output, "## Trigger Toggled"
    assert_includes output, "- **New Status:** disabled"
  end

  test "requires an id for actions that operate on an existing trigger" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "toggle") }

    assert_match(/"id" is required for the "toggle" action/, error.message)
  end

  test "rejects an unknown action" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "explode") }

    assert_match(/Unknown action "explode"/, error.message)
  end

  test "requires an action" do
    assert_raises(Mcp::ToolError) { @tool.call({}) }
  end
end
