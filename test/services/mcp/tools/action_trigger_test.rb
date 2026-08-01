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

  # --- Multi-condition support ----------------------------------------------
  #
  # A Trigger ORs its conditions and both the web UI and the REST API can express
  # several. Until the `conditions` array existed this tool could not, so the
  # two-condition passive-listening trigger the feature was built for was
  # unexpressible through MCP.

  test "creates a trigger with two conditions" do
    output = @tool.call(
      "action" => "create",
      "name" => "MCP Passive Listener",
      "agent_root_name" => "zimmer",
      "prompt_template" => "Something landed: {{link}}",
      "conditions" => [
        { "trigger_type" => "slack", "configuration" => { "event_type" => "passive_listen_thread" } },
        { "trigger_type" => "slack", "configuration" => { "event_type" => "passive_listen_channel" } }
      ]
    )

    trigger = Trigger.find_by!(name: "MCP Passive Listener")
    assert_equal 2, trigger.trigger_conditions.count
    assert_equal %w[passive_listen_channel passive_listen_thread],
                 trigger.trigger_conditions.map(&:event_type).sort
    # Each condition's id is surfaced so the next update can address one of them.
    trigger.trigger_conditions.each { |condition| assert_includes output, "[id #{condition.id}]" }
  end

  test "create requires a trigger_type on every element of conditions" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call(
        "action" => "create",
        "name" => "Half Specified",
        "agent_root_name" => "zimmer",
        "prompt_template" => "x",
        "conditions" => [
          { "trigger_type" => "slack", "configuration" => {} },
          { "configuration" => { "event_type" => "passive_listen_channel" } }
        ]
      )
    end

    assert_match(/conditions\[1\] is missing "trigger_type"/, error.message)
  end

  test "conditions and the flat trigger_type pair are mutually exclusive" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call(
        "action" => "create",
        "name" => "Ambiguous",
        "trigger_type" => "slack",
        "agent_root_name" => "zimmer",
        "prompt_template" => "x",
        "conditions" => [ { "trigger_type" => "slack", "configuration" => {} } ]
      )
    end

    assert_match(/cannot be combined/, error.message)
  end

  test "update adds a second condition alongside the existing one" do
    trigger = triggers(:enabled_slack_trigger)
    existing = trigger.trigger_conditions.sole

    output = @tool.call(
      "action" => "update",
      "id" => trigger.id,
      "conditions" => [
        { "id" => existing.id, "configuration" => { "event_type" => "passive_listen_thread", "channel_id" => "C123" } },
        { "trigger_type" => "slack", "configuration" => { "event_type" => "passive_listen_channel", "channel_id" => "C123" } }
      ]
    )

    trigger.reload
    assert_equal 2, trigger.trigger_conditions.count
    assert_equal %w[passive_listen_channel passive_listen_thread],
                 trigger.trigger_conditions.map(&:event_type).sort
    # The existing row was edited in place, not replaced.
    assert_includes trigger.trigger_conditions.map(&:id), existing.id
    assert_includes output, "[id #{existing.id}]"
  end

  # The whole reason update is an upsert: these keys are the Slack poller's only
  # copy of its cursors, and a replace would take them with it.
  test "update preserves poller cursors and the allow-list of a condition it edits" do
    trigger = triggers(:enabled_slack_trigger)
    existing = trigger.trigger_conditions.sole
    existing.update!(configuration: existing.configuration.merge(
      "channel_timestamps" => { "C123" => "1704067200.000000" },
      "thread_timestamps" => { "C123:1704060000.000000" => "1704067100.000000" },
      "bot_activity_timestamps" => { "C123" => "1704067000.000000" },
      "participating_threads" => [ "C123:1704060000.000000" ],
      "allowed_user_ids" => %w[U222]
    ))

    @tool.call(
      "action" => "update",
      "id" => trigger.id,
      "conditions" => [
        { "id" => existing.id, "configuration" => { "event_type" => "passive_listen_thread", "channel_id" => "C123" } }
      ]
    )

    existing.reload
    assert_equal "passive_listen_thread", existing.event_type
    assert_equal({ "C123" => "1704067200.000000" }, existing.channel_timestamps)
    assert_equal({ "C123:1704060000.000000" => "1704067100.000000" }, existing.thread_timestamps)
    assert_equal({ "C123" => "1704067000.000000" }, existing.bot_activity_timestamps)
    assert_equal [ "C123:1704060000.000000" ], existing.participating_threads
    assert_equal %w[U222], existing.allowed_user_ids
  end

  test "update leaves a condition the conditions array does not mention alone" do
    trigger = triggers(:multi_condition_trigger)
    untouched = trigger.trigger_conditions.find { |c| c.condition_type == "schedule" }
    edited = trigger.trigger_conditions.find { |c| c.condition_type == "slack" }
    before = untouched.configuration

    @tool.call(
      "action" => "update",
      "id" => trigger.id,
      "conditions" => [ { "id" => edited.id, "configuration" => { "channel_id" => "C_NEW" } } ]
    )

    trigger.reload
    assert_equal 3, trigger.trigger_conditions.count
    assert_equal before, untouched.reload.configuration
    assert_equal "C_NEW", edited.reload.channel_id
  end

  test "update omitting a condition's configuration leaves that configuration as it is" do
    trigger = triggers(:enabled_slack_trigger)
    existing = trigger.trigger_conditions.sole
    before = existing.configuration

    @tool.call(
      "action" => "update",
      "id" => trigger.id,
      "conditions" => [ { "id" => existing.id } ]
    )

    assert_equal before, existing.reload.configuration
  end

  test "update removes a condition only when asked explicitly" do
    trigger = triggers(:multi_condition_trigger)
    doomed = trigger.trigger_conditions.find { |c| c.condition_type == "schedule" }

    @tool.call(
      "action" => "update",
      "id" => trigger.id,
      "conditions" => [ { "id" => doomed.id, "remove" => true } ]
    )

    trigger.reload
    assert_equal 2, trigger.trigger_conditions.count
    assert_nil TriggerCondition.find_by(id: doomed.id)
  end

  test "update rejects a remove without an id, and an id from another trigger" do
    trigger = triggers(:enabled_slack_trigger)

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id,
                 "conditions" => [ { "trigger_type" => "slack", "remove" => true } ])
    end
    assert_match(/sets "remove" without an "id"/, error.message)

    foreign = triggers(:multi_condition_trigger).trigger_conditions.first
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id,
                 "conditions" => [ { "id" => foreign.id, "configuration" => {} } ])
    end
    assert_match(/does not belong to trigger/, error.message)
  end

  test "update rejects an added condition with no trigger_type" do
    trigger = triggers(:enabled_slack_trigger)

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id,
                 "conditions" => [ { "configuration" => { "channel_id" => "C1" } } ])
    end

    assert_match(/conditions\[0\] is missing "trigger_type"/, error.message)
  end

  # The most likely way to misuse an upsert: read the trigger, send back what you
  # believe is the desired final state, forget to echo the ids. Obeying that would
  # double every condition — and the duplicates would be un-baselined while the
  # originals kept the cursors.
  test "update refuses to append a condition identical to one the trigger already has" do
    trigger = triggers(:enabled_slack_trigger)
    existing = trigger.trigger_conditions.sole

    error = assert_raises(Mcp::ToolError) do
      @tool.call(
        "action" => "update",
        "id" => trigger.id,
        "conditions" => [
          { "trigger_type" => "slack",
            "configuration" => { "event_type" => existing.event_type, "channel_id" => existing.channel_id } }
        ]
      )
    end

    assert_match(/identical to condition #{existing.id}/, error.message)
    assert_equal 1, trigger.reload.trigger_conditions.count
  end

  test "update still appends a condition that listens to something different" do
    trigger = triggers(:enabled_slack_trigger)
    existing = trigger.trigger_conditions.sole

    @tool.call(
      "action" => "update",
      "id" => trigger.id,
      "conditions" => [
        { "trigger_type" => "slack",
          "configuration" => { "event_type" => "passive_listen_channel", "channel_id" => existing.channel_id } }
      ]
    )

    assert_equal 2, trigger.reload.trigger_conditions.count
  end

  test "update rejects a conditions array that names the same condition twice" do
    trigger = triggers(:enabled_slack_trigger)
    existing = trigger.trigger_conditions.sole

    error = assert_raises(Mcp::ToolError) do
      @tool.call(
        "action" => "update",
        "id" => trigger.id,
        "conditions" => [
          { "id" => existing.id, "configuration" => { "event_type" => "new_message", "channel_id" => "C1" } },
          { "id" => existing.id, "remove" => true }
        ]
      )
    end

    assert_match(/more than once/, error.message)
    assert_equal existing.configuration, existing.reload.configuration
  end

  # Dropping event_type is not a small mistake: the reader defaults to new_message,
  # so a passive condition would silently start firing on every message.
  test "update refuses a configuration that would silently reset event_type" do
    trigger = triggers(:enabled_slack_trigger)
    existing = trigger.trigger_conditions.sole
    existing.update!(configuration: existing.configuration.merge("event_type" => "passive_listen_thread"))

    error = assert_raises(Mcp::ToolError) do
      @tool.call(
        "action" => "update",
        "id" => trigger.id,
        "conditions" => [ { "id" => existing.id, "configuration" => { "channel_id" => "C_NEW" } } ]
      )
    end

    assert_match(/would reset it to "new_message"/, error.message)
    assert_equal "passive_listen_thread", existing.reload.event_type
  end

  test "update rejects an added condition with no configuration, and an unknown trigger_type" do
    trigger = triggers(:enabled_slack_trigger)

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id,
                 "conditions" => [ { "trigger_type" => "schedule" } ])
    end
    assert_match(/missing "configuration"/, error.message)

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id,
                 "conditions" => [ { "trigger_type" => "ao_event", "configuration" => { "event_name" => "session_failed" } } ])
    end
    assert_match(/unknown trigger_type/, error.message)
  end

  test "an empty conditions array is refused rather than silently ignored" do
    trigger = triggers(:enabled_slack_trigger)

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id, "conditions" => [])
    end

    assert_match(/sent empty/, error.message)
    assert_equal 1, trigger.reload.trigger_conditions.count
  end

  test "create rejects a conditions element carrying id or remove" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call(
        "action" => "create", "name" => "Bad Create", "agent_root_name" => "zimmer",
        "prompt_template" => "x",
        "conditions" => [ { "id" => 5, "trigger_type" => "slack", "configuration" => { "channel_id" => "C1" } } ]
      )
    end

    assert_match(/only apply when updating/, error.message)
  end

  # The flat contract names a TYPE, which stopped identifying one condition as soon
  # as a trigger could carry two of the same type.
  test "a flat update is refused when the trigger has two conditions of that type" do
    trigger = triggers(:enabled_slack_trigger)
    trigger.trigger_conditions.create!(
      condition_type: "slack",
      configuration: { "event_type" => "passive_listen_channel", "channel_id" => "C_OTHER" }
    )

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id,
                 "trigger_type" => "slack", "configuration" => { "channel_id" => "C_X" })
    end

    assert_match(/does not identify one/, error.message)
    assert_match(/conditions/, error.message)
  end

  test "removing the last condition is refused by the model rather than leaving a condition-less trigger" do
    trigger = triggers(:enabled_slack_trigger)
    existing = trigger.trigger_conditions.sole

    assert_raises(ActiveRecord::RecordInvalid) do
      @tool.call("action" => "update", "id" => trigger.id,
                 "conditions" => [ { "id" => existing.id, "remove" => true } ])
    end

    assert_equal 1, trigger.reload.trigger_conditions.count
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
