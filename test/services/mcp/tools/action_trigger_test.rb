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

  test "creates a trigger with a burst cap, and clears it on update" do
    output = @tool.call(
      "action" => "create",
      "name" => "Capped Watcher",
      "trigger_type" => "slack",
      "agent_root_name" => "zimmer",
      "prompt_template" => "New message: {{link}}",
      "max_sessions_per_minute" => 3,
      "configuration" => { "channel_id" => "C123", "channel_name" => "alerts" }
    )

    trigger = Trigger.find_by!(name: "Capped Watcher")
    assert_equal 3, trigger.max_sessions_per_minute
    assert_includes output, "- **Max Sessions/Minute:** 3"

    update_output = @tool.call("action" => "update", "id" => trigger.id, "max_sessions_per_minute" => nil)
    assert_nil trigger.reload.max_sessions_per_minute
    assert_includes update_output, "- **Max Sessions/Minute:** (no limit)"
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

  test "delete is blocked when the trigger's agent root is outside the allow list" do
    trigger = triggers(:new_slack_trigger)

    error = assert_raises(Mcp::ToolError) do
      restricted_tool("pulsemcp").call("action" => "delete", "id" => trigger.id)
    end

    assert_match(/not permitted/, error.message)
    assert Trigger.exists?(trigger.id), "a restricted connection must not delete another root's trigger"
  end

  test "toggle is blocked when the trigger's agent root is outside the allow list" do
    trigger = triggers(:enabled_slack_trigger)

    error = assert_raises(Mcp::ToolError) do
      restricted_tool("pulsemcp").call("action" => "toggle", "id" => trigger.id)
    end

    assert_match(/not permitted/, error.message)
    assert_equal "enabled", trigger.reload.status, "a restricted connection must not disable another root's trigger"
  end

  test "changing a condition's type replaces the condition instead of appending one" do
    trigger = triggers(:enabled_slack_trigger)

    @tool.call(
      "action" => "update",
      "id" => trigger.id,
      "trigger_type" => "schedule",
      "configuration" => { "schedule_type" => "one_time", "scheduled_at" => "2030-01-01T09:00:00", "timezone" => "UTC" }
    )

    trigger.reload
    assert_equal [ "schedule" ], trigger.trigger_conditions.map(&:condition_type),
      "the old slack condition must be gone — conditions are OR'd, so it would keep firing"
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

  test "creates a github_label trigger" do
    output = @tool.call(
      "action" => "create",
      "name" => "Ready To Merge Gate",
      "trigger_type" => "github_label",
      "agent_root_name" => "zimmer",
      "prompt_template" => 'Rate {{repo}}#{{number}}: {{link}}',
      "configuration" => {
        "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ],
        "target" => "pull_request",
        "labels" => [ "ready to merge" ]
      }
    )

    condition = Trigger.find_by!(name: "Ready To Merge Gate").trigger_conditions.sole
    assert_equal "github_label", condition.condition_type
    assert_equal [ "tadasant/zimmer", "tadasant/zimmer-catalog" ], condition.github_repos
    assert_equal [ "ready to merge" ], condition.github_labels
    assert condition.github_pull_requests?
    assert_includes output, "- **Conditions:** github_label"
  end

  test "creates a github_issue trigger" do
    @tool.call(
      "action" => "create",
      "name" => "Issue Triage",
      "trigger_type" => "github_issue",
      "agent_root_name" => "zimmer",
      "prompt_template" => "Triage {{link}}",
      "configuration" => { "repos" => [ "tadasant/zimmer" ] }
    )

    condition = Trigger.find_by!(name: "Issue Triage").trigger_conditions.sole
    assert_equal "github_issue", condition.condition_type
    assert_equal [ "tadasant/zimmer" ], condition.github_repos
  end

  test "rejects a github trigger with a malformed repo" do
    assert_raises(ActiveRecord::RecordInvalid) do
      @tool.call(
        "action" => "create",
        "name" => "Bad Repo",
        "trigger_type" => "github_issue",
        "agent_root_name" => "zimmer",
        "prompt_template" => "Triage {{link}}",
        "configuration" => { "repos" => [ "not-a-repo" ] }
      )
    end
  end

  test "requires an action" do
    assert_raises(Mcp::ToolError) { @tool.call({}) }
  end
end
