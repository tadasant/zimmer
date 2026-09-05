# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

class Mcp::Tools::ActionTriggerTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::ActionTrigger.new(context: Mcp::Context.new(tool_groups: "triggers"))
  end

  def restricted_tool(roots = "zimmer")
    Mcp::Tools::ActionTrigger.new(context: Mcp::Context.new(tool_groups: "triggers", allowed_agent_roots: roots))
  end

  test "a created trigger carries no class by default, and says which it derives" do
    output = @tool.call(
      "action" => "create",
      "name" => "Derived Class Trigger",
      "trigger_type" => "slack",
      "agent_root_name" => "zimmer",
      "prompt_template" => "{{link}}",
      "configuration" => { "channel_id" => "C777", "channel_name" => "derived" }
    )

    trigger = Trigger.find_by!(name: "Derived Class Trigger")
    assert_nil trigger.scheduling_class
    assert_includes output, "- **Scheduling Class:** priority (default for its conditions)"
  end

  test "create accepts a scheduling_class" do
    @tool.call(
      "action" => "create",
      "name" => "Spot Slack Trigger",
      "trigger_type" => "slack",
      "agent_root_name" => "zimmer",
      "prompt_template" => "{{link}}",
      "scheduling_class" => "spot",
      "configuration" => { "channel_id" => "C888", "channel_name" => "noisy" }
    )

    assert_equal SessionGenesis::SPOT, Trigger.find_by!(name: "Spot Slack Trigger").scheduling_class
  end

  test "update sets and clears the scheduling_class" do
    trigger = triggers(:enabled_schedule_trigger)

    output = @tool.call("action" => "update", "id" => trigger.id, "scheduling_class" => "priority")
    assert_equal SessionGenesis::PRIORITY, trigger.reload.scheduling_class
    assert_includes output, "- **Scheduling Class:** priority (set on this trigger)"

    @tool.call("action" => "update", "id" => trigger.id, "scheduling_class" => nil)
    assert_nil trigger.reload.scheduling_class, "an explicit null returns it to derived"
  end

  test "an omitted scheduling_class leaves an existing choice alone" do
    trigger = triggers(:enabled_schedule_trigger)
    trigger.update!(scheduling_class: SessionGenesis::PRIORITY)

    @tool.call("action" => "update", "id" => trigger.id, "name" => "Renamed But Still Priority")

    assert_equal SessionGenesis::PRIORITY, trigger.reload.scheduling_class
  end

  test "an unknown scheduling_class is rejected" do
    trigger = triggers(:enabled_schedule_trigger)
    assert_raises(ActiveRecord::RecordInvalid) do
      @tool.call("action" => "update", "id" => trigger.id, "scheduling_class" => "whenever")
    end
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

  test "creates a trigger with a predefined precedence, and clears it on update" do
    output = @tool.call(
      "action" => "create",
      "name" => "Ranked Watcher",
      "trigger_type" => "slack",
      "agent_root_name" => "zimmer",
      "prompt_template" => "New message: {{link}}",
      "precedence" => 900,
      "configuration" => { "channel_id" => "C123", "channel_name" => "alerts" }
    )

    trigger = Trigger.find_by!(name: "Ranked Watcher")
    assert_equal 900, trigger.precedence
    assert_includes output, "- **Precedence:** 900"

    # An explicit null clears it; an omitted key would leave it alone.
    @tool.call("action" => "update", "id" => trigger.id, "precedence" => nil)
    assert_nil trigger.reload.precedence

    @tool.call("action" => "update", "id" => trigger.id, "precedence" => 42)
    assert_equal 42, trigger.reload.precedence

    @tool.call("action" => "update", "id" => trigger.id, "name" => "Ranked Watcher 2")
    assert_equal 42, trigger.reload.precedence, "an omitted key is no opinion, not a clear"
  end

  test "a non-integer precedence is a tool error" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call(
        "action" => "create",
        "name" => "Bad Precedence",
        "trigger_type" => "slack",
        "agent_root_name" => "zimmer",
        "prompt_template" => "x",
        "precedence" => "high",
        "configuration" => { "channel_id" => "C123", "channel_name" => "alerts" }
      )
    end
    assert_match(/precedence must be an integer/, error.message)
  end

  test "the precedence description states the absolute scale" do
    description = Mcp::Tools::ActionTrigger.input_schema.to_h.dig(:properties, :precedence, :description)

    assert_match(/absolute scale/i, description)
    assert_match(/100000 comes before 50/, description)
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

  test "creates a trigger with skip_if_pending_session, and turns it off on update" do
    output = @tool.call(
      "action" => "create",
      "name" => "Deduped Watcher",
      "trigger_type" => "slack",
      "agent_root_name" => "zimmer",
      "prompt_template" => "New message: {{link}}",
      "skip_if_pending_session" => true,
      "configuration" => { "channel_id" => "C123", "channel_name" => "alerts" }
    )

    trigger = Trigger.find_by!(name: "Deduped Watcher")
    assert trigger.skip_if_pending_session
    assert_includes output, "- **Skip While Pending:** yes"

    update_output = @tool.call("action" => "update", "id" => trigger.id, "skip_if_pending_session" => false)
    assert_not trigger.reload.skip_if_pending_session
    assert_includes update_output, "- **Skip While Pending:** no"
  end

  test "skip_if_pending_session defaults to off when the caller says nothing" do
    @tool.call(
      "action" => "create",
      "name" => "Quiet Watcher",
      "trigger_type" => "slack",
      "agent_root_name" => "zimmer",
      "prompt_template" => "New message: {{link}}",
      "configuration" => { "channel_id" => "C123", "channel_name" => "alerts" }
    )

    assert_not Trigger.find_by!(name: "Quiet Watcher").skip_if_pending_session
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
                 "conditions" => [ { "trigger_type" => "carrier_pigeon", "configuration" => { "loft" => "north" } } ])
    end
    assert_match(/unknown trigger_type/, error.message)
  end

  # === Zimmer event parity ===
  #
  # The /triggers form has always offered ao_event, so an MCP surface that could
  # not create one made the web UI strictly more capable than an agent session.
  # These are the parity tests for closing that gap.

  test "create accepts an ao_event trigger" do
    result = @tool.call(
      "action" => "create",
      "name" => "Reauth notifier",
      "trigger_type" => "ao_event",
      "agent_root_name" => "general-agent",
      "prompt_template" => "{{event}} — tell someone",
      "mcp_servers" => [ "slack-workspace" ],
      "configuration" => { "event_name" => "account_needs_reauth" }
    )

    created = Trigger.find_by(name: "Reauth notifier")
    assert_not_nil created, result
    condition = created.trigger_conditions.sole
    assert_equal "ao_event", condition.condition_type
    assert_equal "account_needs_reauth", condition.ao_event_name
    assert_predicate condition, :account_ao_event?
  end

  test "create accepts a broadcast session ao_event trigger" do
    @tool.call(
      "action" => "create",
      "name" => "Any session needing input",
      "trigger_type" => "ao_event",
      "agent_root_name" => "general-agent",
      "prompt_template" => "{{event}}",
      "configuration" => { "event_name" => "session_needs_input" }
    )

    condition = Trigger.find_by(name: "Any session needing input").trigger_conditions.sole
    assert_equal "session_needs_input", condition.ao_event_name
    assert_not condition.session_scoped_ao_event?
  end

  # Invalid configuration surfaces as RecordInvalid from `trigger.save!`, the same
  # way a Slack condition with no channel_id does.
  test "create rejects an ao_event with an event_name Zimmer does not emit" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      @tool.call(
        "action" => "create",
        "name" => "Bogus event",
        "trigger_type" => "ao_event",
        "agent_root_name" => "general-agent",
        "prompt_template" => "{{event}}",
        "configuration" => { "event_name" => "the_vibes_shifted" }
      )
    end

    assert_match(/event_name must be one of/, error.message)
  end

  test "create rejects watched_session_id on an account event" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      @tool.call(
        "action" => "create",
        "name" => "Confused event",
        "trigger_type" => "ao_event",
        "agent_root_name" => "general-agent",
        "prompt_template" => "{{event}}",
        "configuration" => { "event_name" => "account_needs_reauth", "watched_session_id" => sessions(:needs_input).id }
      )
    end

    assert_match(/only meaningful for session events/, error.message)
  end

  # === Guards on the capability opening ao_event creation introduced ===

  test "update refuses to silently widen a session-scoped wake into a broadcast" do
    trigger = Trigger.create!(
      name: "One-shot wake",
      agent_root_name: "zimmer",
      prompt_template: "{{event}}",
      trigger_conditions_attributes: [ {
        condition_type: "ao_event",
        configuration: { "event_name" => "session_needs_input", "watched_session_id" => sessions(:needs_input).id }
      } ]
    )
    condition = trigger.trigger_conditions.sole

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id,
                 "conditions" => [ { "id" => condition.id, "configuration" => { "event_name" => "session_needs_input" } } ])
    end

    assert_match(/watched_session_id/, error.message)
    assert_match(/broadcast/, error.message)
    assert_equal sessions(:needs_input).id, condition.reload.watched_session_id
  end

  test "a broadcast session ao_event created here gets a burst cap by default" do
    @tool.call(
      "action" => "create",
      "name" => "Unbounded broadcast",
      "trigger_type" => "ao_event",
      "agent_root_name" => "zimmer",
      "prompt_template" => "{{event}}",
      "configuration" => { "event_name" => "session_archived" }
    )

    assert_equal Mcp::Tools::ActionTrigger::BROADCAST_SESSION_AO_EVENT_BURST_CAP,
                 Trigger.find_by!(name: "Unbounded broadcast").max_sessions_per_minute
  end

  test "an explicit cap still wins over the default" do
    @tool.call(
      "action" => "create",
      "name" => "Explicit cap",
      "trigger_type" => "ao_event",
      "agent_root_name" => "zimmer",
      "prompt_template" => "{{event}}",
      "max_sessions_per_minute" => 20,
      "configuration" => { "event_name" => "session_archived" }
    )

    assert_equal 20, Trigger.find_by!(name: "Explicit cap").max_sessions_per_minute
  end

  # An account event is already bounded at source, and a burst cap there could only
  # drop alerts during the mass failure it exists to report.
  test "an account ao_event gets no default cap" do
    @tool.call(
      "action" => "create",
      "name" => "Account watcher",
      "trigger_type" => "ao_event",
      "agent_root_name" => "zimmer",
      "prompt_template" => "{{event}}",
      "configuration" => { "event_name" => "account_needs_reauth" }
    )

    assert_nil Trigger.find_by!(name: "Account watcher").max_sessions_per_minute
  end

  test "a session-scoped ao_event gets no default cap either" do
    @tool.call(
      "action" => "create",
      "name" => "Scoped wake",
      "trigger_type" => "ao_event",
      "agent_root_name" => "zimmer",
      "prompt_template" => "{{event}}",
      "configuration" => { "event_name" => "session_needs_input", "watched_session_id" => sessions(:needs_input).id }
    )

    assert_nil Trigger.find_by!(name: "Scoped wake").max_sessions_per_minute
  end

  test "a non-ao_event trigger is unaffected by the default" do
    @tool.call(
      "action" => "create",
      "name" => "Plain slack",
      "trigger_type" => "slack",
      "agent_root_name" => "zimmer",
      "prompt_template" => "{{link}}",
      "configuration" => { "channel_id" => "C999", "channel_name" => "plain" }
    )

    assert_nil Trigger.find_by!(name: "Plain slack").max_sessions_per_minute
  end

  test "the creatable types match the condition types the model accepts" do
    # ao_event is the one that drifted. Assert the whole set so the next addition
    # cannot quietly land in the model and the UI but not here.
    assert_equal TriggerCondition::CONDITION_TYPES.sort, Mcp::Tools::ActionTrigger::TRIGGER_TYPES.sort
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

  test "creates a github_issue trigger that excludes labelled issues" do
    @tool.call(
      "action" => "create",
      "name" => "Issue Gate",
      "trigger_type" => "github_issue",
      "agent_root_name" => "zimmer",
      "prompt_template" => "Gate {{link}}",
      "configuration" => {
        "repos" => [ "tadasant/zimmer" ],
        "exclude_labels" => [ "hold issue work gate" ]
      }
    )

    condition = Trigger.find_by!(name: "Issue Gate").trigger_conditions.sole
    assert_equal [ "hold issue work gate" ], condition.github_exclude_labels
  end

  # This is the path that wires an exclusion onto a LIVE gate. Sending a configuration
  # replaces the user-facing keys, so the test that matters is what happens to the keys
  # the caller did NOT send: the poller's cursor.
  test "adding an exclusion through the conditions upsert keeps the github cursor" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update!(configuration: condition.configuration.merge(
      "last_issue_at" => "2026-07-12T09:00:00Z",
      "seen_issue_keys" => [ "tadasant/zimmer#42" ]
    ))

    @tool.call(
      "action" => "update",
      "id" => condition.trigger_id,
      "conditions" => [
        {
          "id" => condition.id,
          "trigger_type" => "github_issue",
          "configuration" => {
            "repos" => [ "tadasant/zimmer" ],
            "exclude_labels" => [ "hold issue work gate" ]
          }
        }
      ]
    )

    condition.reload
    assert_equal [ "hold issue work gate" ], condition.github_exclude_labels
    assert_equal "2026-07-12T09:00:00Z", condition.github_last_issue_at
    assert_equal [ "tadasant/zimmer#42" ], condition.github_seen_issue_keys
  end

  # Dropping the exclusion re-arms the gate for every issue that was opting out of it,
  # and nothing downstream would catch it: exclude_labels is not poller state, so
  # preserve_github_poll_state does not merge it back.
  test "rejects an update that would silently drop a github_issue condition's exclusion" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update!(configuration: condition.configuration.merge(
      "exclude_labels" => [ "hold issue work gate" ]
    ))

    error = assert_raises(Mcp::ToolError) do
      @tool.call(
        "action" => "update",
        "id" => condition.trigger_id,
        "conditions" => [
          {
            "id" => condition.id,
            "trigger_type" => "github_issue",
            "configuration" => { "repos" => [ "tadasant/zimmer" ] }
          }
        ]
      )
    end

    assert_match(/omits "exclude_labels"/, error.message)
    assert_match(/hold issue work gate/, error.message)
    assert_equal [ "hold issue work gate" ], condition.reload.github_exclude_labels
  end

  test "an explicit empty exclude_labels clears the exclusion" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update!(configuration: condition.configuration.merge(
      "exclude_labels" => [ "hold issue work gate" ]
    ))

    @tool.call(
      "action" => "update",
      "id" => condition.trigger_id,
      "conditions" => [
        {
          "id" => condition.id,
          "trigger_type" => "github_issue",
          "configuration" => { "repos" => [ "tadasant/zimmer" ], "exclude_labels" => [] }
        }
      ]
    )

    assert_empty condition.reload.github_exclude_labels
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

  # invoke — firing a trigger by hand, the MCP half of POST /triggers/:id/invoke
  # ---------------------------------------------------------------------------

  def stub_session_creation
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)
  end

  test "the schema and the description both offer invoke" do
    assert_includes Mcp::Tools::ActionTrigger::ACTIONS, "invoke"
    schema = Mcp::Tools::ActionTrigger.input_schema.to_h
    assert_includes schema.dig(:properties, :action, :enum), "invoke"
    assert schema.dig(:properties, :variables), "variables must be part of the tool's contract"
    assert_match(/\*\*invoke\*\*/, Mcp::Tools::ActionTrigger.description)
  end

  test "invoke fires the trigger: a session is linked to it and the fire counter moves" do
    stub_session_creation
    trigger = triggers(:enabled_slack_trigger)
    before_count = trigger.sessions_created_count

    output = nil
    assert_difference("Session.count", 1) do
      output = @tool.call("action" => "invoke", "id" => trigger.id)
    end

    session = Session.last
    assert_equal trigger.id.to_s, session.metadata["trigger_id"].to_s
    assert_equal before_count + 1, trigger.reload.sessions_created_count

    assert_includes output, "## Trigger Invoked"
    assert_includes output, "- **Trigger:** #{trigger.id} — #{trigger.name}"
    assert_includes output, "- **Session:** #{session.id}"
    assert_includes output, "/sessions/#{session.id}"
    assert_includes output, "- **Sessions Created (lifetime):** #{before_count + 1}"
  end

  test "invoke interpolates the variables it is given" do
    stub_session_creation
    trigger = triggers(:enabled_slack_trigger)

    @tool.call(
      "action" => "invoke",
      "id" => trigger.id,
      "variables" => { "link" => "https://example.com/msg/9", "channel" => "eng-alerts", "nonsense" => "dropped" }
    )

    session = Session.last
    assert_includes session.prompt, "https://example.com/msg/9"
    assert_includes session.prompt, "#eng-alerts"
    assert_not_includes session.prompt, "dropped"
  end

  test "a session invoked over MCP carries the api genesis" do
    stub_session_creation

    @tool.call("action" => "invoke", "id" => triggers(:enabled_slack_trigger).id)

    assert_equal SessionGenesis::API, Session.last.genesis
  end

  test "invoke fires a disabled trigger without re-arming it" do
    stub_session_creation
    trigger = triggers(:disabled_slack_trigger)

    assert_difference("Session.count", 1) do
      @tool.call("action" => "invoke", "id" => trigger.id)
    end

    assert_equal "disabled", trigger.reload.status
  end

  test "invoke says so when the burst cap left nothing to create" do
    stub_session_creation
    trigger = triggers(:enabled_slack_trigger)
    trigger.update!(max_sessions_per_minute: 1)

    @tool.call("action" => "invoke", "id" => trigger.id)

    notice = @tool.call("action" => "invoke", "id" => trigger.id)
    assert_includes notice, "## Trigger Invoked — Burst Notice"
    assert_match(/burst-notice session it spawned instead/, notice)

    suppressed = nil
    assert_no_difference("Session.count") do
      suppressed = @tool.call("action" => "invoke", "id" => trigger.id)
    end
    assert_includes suppressed, "## Trigger Not Fired"
    assert_match(/is in a burst/, suppressed)
  end

  test "invoke reports a target session it declined to reuse rather than claiming a fire" do
    stub_session_creation
    trigger = triggers(:enabled_slack_trigger)
    target = sessions(:failed)
    trigger.update!(reuse_session: true, last_session_id: target.id)
    Trigger.any_instance.stubs(:one_time_reuse_trigger?).returns(true)

    output = nil
    assert_no_difference("Session.count") do
      output = @tool.call("action" => "invoke", "id" => trigger.id)
    end

    assert_includes output, "## Trigger Not Fired"
    assert_match(/no longer reusable/, output)
    assert_includes output, "Target session: #{target.id}"
  end

  test "invoke turns an unresolvable agent root into a readable tool error" do
    AgentRootsConfig.stubs(:find!).raises(AgentRootsConfig::AgentRootNotFoundError.new("Not found"))
    trigger = triggers(:enabled_slack_trigger)

    before_sessions = Session.count
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "invoke", "id" => trigger.id) }

    assert_match(/Invalid agent_root/, error.message)
    assert_equal before_sessions, Session.count
  end

  test "invoke requires an id" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "invoke") }

    assert_match(/"id" is required for the "invoke" action/, error.message)
  end

  test "invoke is blocked when the trigger's agent root is outside the allow list" do
    trigger = triggers(:enabled_slack_trigger)

    before_sessions = Session.count
    error = assert_raises(Mcp::ToolError) do
      restricted_tool("pulsemcp").call("action" => "invoke", "id" => trigger.id)
    end

    assert_match(/not permitted/, error.message)
    assert_equal before_sessions, Session.count, "a restricted connection must not fire another root's trigger"
  end

  # --- enqueue_messages / resuscitate_archived --------------------------------

  test "create stores enqueue_messages and resuscitate_archived alongside reuse_session" do
    output = @tool.call(
      "action" => "create",
      "name" => "Queueing Reuse Trigger",
      "trigger_type" => "slack",
      "agent_root_name" => "zimmer",
      "prompt_template" => "{{link}}",
      "reuse_session" => true,
      "enqueue_messages" => true,
      "resuscitate_archived" => true,
      "configuration" => { "channel_id" => "C1010", "channel_name" => "queueing" }
    )

    trigger = Trigger.find_by!(name: "Queueing Reuse Trigger")
    assert trigger.enqueue_messages, "enqueue_messages must land on the record"
    assert trigger.resuscitate_archived, "resuscitate_archived must land on the record"
    assert_includes output, "- **Reuse Session:** yes (enqueue messages: yes, resuscitate archived: yes)"
  end

  test "update sets enqueue_messages and resuscitate_archived on an existing reuse trigger" do
    trigger = triggers(:weekly_schedule_trigger)
    refute trigger.enqueue_messages

    output = @tool.call(
      "action" => "update",
      "id" => trigger.id,
      "enqueue_messages" => true,
      "resuscitate_archived" => true
    )

    trigger.reload
    assert trigger.enqueue_messages
    assert trigger.resuscitate_archived
    assert_includes output, "- **Reuse Session:** yes (enqueue messages: yes, resuscitate archived: yes)"
  end

  test "update can turn enqueue_messages back off" do
    trigger = triggers(:weekly_schedule_trigger)
    trigger.update!(enqueue_messages: true)

    @tool.call("action" => "update", "id" => trigger.id, "enqueue_messages" => false)

    refute trigger.reload.enqueue_messages
  end

  test "update leaves enqueue_messages alone when the key is omitted" do
    trigger = triggers(:weekly_schedule_trigger)
    trigger.update!(enqueue_messages: true, resuscitate_archived: true)

    @tool.call("action" => "update", "id" => trigger.id, "name" => "Weekly Report Renamed")

    trigger.reload
    assert trigger.enqueue_messages
    assert trigger.resuscitate_archived
  end

  test "create rejects enqueue_messages without reuse_session rather than silently clearing it" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call(
        "action" => "create",
        "name" => "Dropped Wake Trigger",
        "trigger_type" => "slack",
        "agent_root_name" => "zimmer",
        "prompt_template" => "{{link}}",
        "enqueue_messages" => true,
        "configuration" => { "channel_id" => "C1011", "channel_name" => "dropped" }
      )
    end

    assert_match(/"enqueue_messages" requires "reuse_session"/, error.message)
    assert_nil Trigger.find_by(name: "Dropped Wake Trigger"), "nothing may be created when the flag is refused"
  end

  test "update rejects enqueue_messages on a trigger that does not reuse its session" do
    trigger = triggers(:enabled_slack_trigger)
    refute trigger.reuse_session

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id, "enqueue_messages" => true)
    end

    assert_match(/"enqueue_messages" requires "reuse_session"/, error.message)
    refute trigger.reload.enqueue_messages
  end

  test "update accepts enqueue_messages when the same call turns reuse_session on" do
    trigger = triggers(:enabled_slack_trigger)

    @tool.call("action" => "update", "id" => trigger.id, "reuse_session" => true, "enqueue_messages" => true)

    trigger.reload
    assert trigger.reuse_session
    assert trigger.enqueue_messages
  end

  test "update rejects enqueue_messages when the same call turns reuse_session off" do
    trigger = triggers(:weekly_schedule_trigger)
    trigger.update!(enqueue_messages: true)

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id, "reuse_session" => false, "enqueue_messages" => true)
    end

    assert_match(/"enqueue_messages" requires "reuse_session"/, error.message)
    assert trigger.reload.reuse_session, "the refused call must not have changed anything"
  end

  test "update rejects resuscitate_archived without reuse_session" do
    trigger = triggers(:enabled_slack_trigger)

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id, "resuscitate_archived" => true)
    end

    assert_match(/"resuscitate_archived" requires "reuse_session"/, error.message)
    refute trigger.reload.resuscitate_archived
  end

  test "enqueue_messages: false without reuse_session is not an error" do
    trigger = triggers(:enabled_slack_trigger)

    @tool.call("action" => "update", "id" => trigger.id, "enqueue_messages" => false)

    refute trigger.reload.enqueue_messages
  end

  # --- catalog_skills / catalog_hooks / catalog_plugins -----------------------

  test "create stores the three catalog lists for the sessions the trigger spawns" do
    output = @tool.call(
      "action" => "create",
      "name" => "Equipped Trigger",
      "trigger_type" => "slack",
      "agent_root_name" => "zimmer",
      "prompt_template" => "{{link}}",
      "catalog_skills" => [ "zimmer-run-tests" ],
      "catalog_hooks" => [ "git-push-ci-reminder" ],
      "catalog_plugins" => [ "ci-workflow" ],
      "configuration" => { "channel_id" => "C1012", "channel_name" => "equipped" }
    )

    trigger = Trigger.find_by!(name: "Equipped Trigger")
    assert_equal [ "zimmer-run-tests" ], trigger.catalog_skills
    assert_equal [ "git-push-ci-reminder" ], trigger.catalog_hooks
    assert_equal [ "ci-workflow" ], trigger.catalog_plugins
    assert_includes output, "skills: zimmer-run-tests | hooks: git-push-ci-reminder | plugins: ci-workflow"
  end

  test "update replaces a trigger's catalog skills" do
    trigger = triggers(:enabled_slack_trigger)
    trigger.update!(catalog_skills: [ "zimmer-run-tests" ])

    @tool.call("action" => "update", "id" => trigger.id, "catalog_skills" => [ "open-pr" ])

    assert_equal [ "open-pr" ], trigger.reload.catalog_skills
  end

  test "update clears a catalog list on an explicit empty array and leaves it alone on an omitted key" do
    trigger = triggers(:enabled_slack_trigger)
    trigger.update!(catalog_skills: [ "zimmer-run-tests" ], catalog_hooks: [ "git-push-ci-reminder" ])

    @tool.call("action" => "update", "id" => trigger.id, "catalog_skills" => [])

    trigger.reload
    assert_equal [], trigger.catalog_skills
    assert_equal [ "git-push-ci-reminder" ], trigger.catalog_hooks, "an omitted list means no opinion, not clear"
  end

  test "create rejects an unknown skill id and lists the valid ones" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call(
        "action" => "create",
        "name" => "Bad Skill Trigger",
        "trigger_type" => "slack",
        "agent_root_name" => "zimmer",
        "prompt_template" => "{{link}}",
        "catalog_skills" => [ "zimmer-run-tests", "not-a-skill" ],
        "configuration" => { "channel_id" => "C1013", "channel_name" => "bad" }
      )
    end

    assert_match(/Invalid skills: not-a-skill/, error.message)
    assert_match(/Valid skills:/, error.message)
    assert_nil Trigger.find_by(name: "Bad Skill Trigger")
  end

  test "update rejects an unknown hook id" do
    trigger = triggers(:enabled_slack_trigger)

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id, "catalog_hooks" => [ "not-a-hook" ])
    end

    assert_match(/Invalid hooks: not-a-hook/, error.message)
    assert_equal [], trigger.reload.catalog_hooks
  end

  test "update rejects an unknown plugin id" do
    trigger = triggers(:enabled_slack_trigger)

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id, "catalog_plugins" => [ "not-a-plugin" ])
    end

    assert_match(/Invalid plugins: not-a-plugin/, error.message)
  end

  test "the input schema names every trigger field the web form can set" do
    properties = Mcp::Tools::ActionTrigger.input_schema.to_h[:properties]

    %i[enqueue_messages resuscitate_archived catalog_skills catalog_hooks catalog_plugins].each do |field|
      assert properties.key?(field), "action_trigger's schema must name #{field}"
    end
  end

  test "catalog_plugins is refused on a restricted connection" do
    trigger = triggers(:enabled_slack_trigger)

    error = assert_raises(Mcp::ToolError) do
      restricted_tool("zimmer").call("action" => "update", "id" => trigger.id, "catalog_plugins" => [ "ci-workflow" ])
    end

    assert_match(/cannot be set when this connection is restricted/, error.message)
    assert_equal [], trigger.reload.catalog_plugins
  end

  test "catalog_skills is allowed on a restricted connection (skills carry no server expansion)" do
    trigger = triggers(:enabled_slack_trigger)

    restricted_tool("zimmer").call("action" => "update", "id" => trigger.id, "catalog_skills" => [ "open-pr" ])

    assert_equal [ "open-pr" ], trigger.reload.catalog_skills
  end

  test "a catalog list sent as something other than an array is rejected, not silently dropped" do
    trigger = triggers(:enabled_slack_trigger)

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id, "catalog_skills" => "open-pr")
    end

    assert_match(/"catalog_skills" parameter must be an array/, error.message)
    assert_equal [], trigger.reload.catalog_skills
  end

  test "a catalog list over its bound is rejected" do
    trigger = triggers(:enabled_slack_trigger)

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "update", "id" => trigger.id, "catalog_skills" => Array.new(101) { "open-pr" })
    end

    assert_match(/Maximum 100 skills/, error.message)
  end

  test "blank ids are dropped from a catalog list rather than reaching the catalog check" do
    trigger = triggers(:enabled_slack_trigger)

    @tool.call("action" => "update", "id" => trigger.id, "catalog_skills" => [ "", "open-pr", "  " ])

    assert_equal [ "open-pr" ], trigger.reload.catalog_skills
  end

  test "an empty catalog list is reported as the agent root defaults, not as none" do
    output = @tool.call("action" => "update", "id" => triggers(:enabled_slack_trigger).id, "catalog_skills" => [])

    assert_includes output, "skills: (agent root defaults)"
    refute_includes output, "skills: (none)"
  end
end
