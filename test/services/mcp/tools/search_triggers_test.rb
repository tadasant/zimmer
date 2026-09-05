# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::SearchTriggersTest < ActiveSupport::TestCase
  Channel = Struct.new(:id, :name, :is_private, :num_members)

  setup do
    @tool = Mcp::Tools::SearchTriggers.new(context: Mcp::Context.new(tool_groups: "triggers"))
  end

  test "lists triggers with pagination header" do
    output = @tool.call({})

    assert_match(/## Triggers \(#{Trigger.count} total, page 1 of \d+\)/, output)
    assert_includes output, "### CI Failure Handler (ID: #{triggers(:enabled_slack_trigger).id})"
    assert_includes output, "- **Conditions:** slack | **Status:** enabled | **Sessions:** 5"
    assert_includes output, "  - Slack: #eng-ci"
  end

  # "Which triggers reference MCP server X?" is the question every catalog rename
  # audit runs on, and the list is the only view built for scanning many triggers.
  test "names each trigger's MCP servers in list mode" do
    output = @tool.call({})

    assert_includes output, "### CI Failure Handler (ID: #{triggers(:enabled_slack_trigger).id})"
    assert_includes output, "**Scheduling Class:** priority (default for its conditions) | " \
                            "**MCP Servers:** slack-workspace\n"
    assert_includes output, "**MCP Servers:** (none)"

    triggers(:enabled_slack_trigger).update!(mcp_servers: %w[slack-workspace github])
    assert_includes @tool.call({}), "**MCP Servers:** slack-workspace, github"
  end

  # A small configuration is the whole point of the by-id view — it is rendered
  # byte for byte, with nothing elided.
  test "renders a small configuration verbatim" do
    condition = trigger_conditions(:enabled_schedule_condition)

    output = @tool.call("id" => condition.trigger_id)

    verbatim = JSON.pretty_generate(condition.reload.configuration)
      .split("\n").map { |line| "  #{line}" }.join("\n")
    assert_includes output, "  ```json\n#{verbatim}\n  ```"
    assert_includes output, '"timezone": "Eastern Time (US & Canada)"'
    assert_not_includes output, "Poller state, summarised"
  end

  # Slack cursor maps grow without bound — SlackTriggerPollerJob rewrites them every
  # minute — and serialising one cost ~15k tokens for a single trigger.
  test "summarises high-cardinality poller state in a large configuration" do
    condition = trigger_conditions(:enabled_slack_condition)
    thread_timestamps = 400.times.to_h do |i|
      [ "C0A6BF8T45R:1788400#{format('%03d', i)}.000000", "1788455#{format('%03d', i)}.688659" ]
    end
    condition.update!(configuration: condition.configuration.merge(
      "thread_timestamps" => thread_timestamps,
      "participating_threads" => thread_timestamps.keys,
      "allowed_user_ids" => (1..20).map { |i| "U#{i}" }
    ))

    output = @tool.call("id" => condition.trigger_id)

    # The shape of the cursor state, not the state itself.
    assert_includes output, "- `thread_timestamps`: 400 entries, most recent 1788455399.688659"
    assert_includes output, "- `participating_threads`: 400 entries, most recent C0A6BF8T45R:1788400399.000000"
    assert_not_includes output, "1788455000.688659"
    assert_includes output, "GET /api/v1/triggers/#{condition.trigger_id}"

    # A summarised key is OMITTED from the JSON rather than given a prose value:
    # the commonest misuse of action_trigger is echoing a configuration back, and
    # preserve_slack_poll_state restores a key that is absent — while a summary
    # sitting under its real key would be written over the live cursor map.
    assert_not_includes output, '"thread_timestamps"'
    assert_not_includes output, '"participating_threads"'

    # Settings a human typed survive intact, however long the configuration got.
    assert_includes output, '"channel_name": "eng-ci"'
    assert_includes output, '"U20"'

    assert_operator output.length, :<, 4_000, "the summarised rendering must not carry the cursor dump"
  end

  # A poller-owned collection under the threshold is not high-cardinality, so it
  # stays in the JSON however large the configuration around it is.
  test "leaves a small poller-owned collection in place" do
    condition = trigger_conditions(:enabled_slack_condition)
    condition.update!(configuration: condition.configuration.merge(
      "thread_timestamps" => 400.times.to_h { |i| [ "C0A6BF8T45R:#{i}", "1788455#{format('%03d', i)}.688659" ] },
      "bot_activity_timestamps" => { "C0A6BF8T45R" => "1788455399.688659" }
    ))

    output = @tool.call("id" => condition.trigger_id)

    assert_includes output, '"bot_activity_timestamps"'
    assert_includes output, '"C0A6BF8T45R": "1788455399.688659"'
    assert_not_includes output, "- `bot_activity_timestamps`:"
  end

  # GitHub poll state carries no timestamps, so the summary names a sample entry
  # instead of a most-recent one.
  test "summarises a collection whose entries carry no timestamp" do
    condition = trigger_conditions(:github_label_condition)
    condition.update!(configuration: condition.configuration.merge(
      "seen_items" => (1..400).map { |i| "tadasant/zimmer#pull_request##{i}" }
    ))

    output = @tool.call("id" => condition.trigger_id)

    assert_includes output, "- `seen_items`: 400 entries, e.g. tadasant/zimmer#pull_request#1"
    assert_not_includes output, '"seen_items"'
    # The user-facing lists are not poller state and are never summarised.
    assert_includes output, '"tadasant/zimmer"'
    assert_includes output, '"ready to merge"'
  end

  # Nothing to summarise means nothing changes: a long configuration with no
  # high-cardinality collection is still rendered in full.
  test "leaves a large configuration without high-cardinality collections verbatim" do
    condition = trigger_conditions(:enabled_slack_condition)
    condition.update!(configuration: condition.configuration.merge("note" => "x" * 3_000))

    output = @tool.call("id" => condition.trigger_id)

    assert_includes output, "x" * 3_000
    assert_not_includes output, "Poller state, summarised"
  end

  test "surfaces skip_if_pending_session, and names the session it is skipping for" do
    trigger = triggers(:enabled_slack_trigger)

    assert_includes @tool.call("id" => trigger.id), "- **Skip While Pending:** No"

    trigger.update!(skip_if_pending_session: true)
    assert_includes @tool.call("id" => trigger.id), "Yes (nothing pending — the next fire spawns)"

    # A trigger skipping every fire spawns nothing at all — say so, and say which
    # session it is deferring to, or a caller wondering why it looks dead has no
    # way to tell.
    pending = sessions(:waiting)
    pending.update!(metadata: pending.metadata.merge("trigger_id" => trigger.id))
    output = @tool.call("id" => trigger.id)
    assert_includes output, "SKIPPING"
    assert_includes output, "session #{pending.id}"
  end

  test "surfaces the burst cap, and flags a trigger that is currently bursting" do
    trigger = triggers(:enabled_slack_trigger)

    assert_includes @tool.call({}), "**Max Sessions/Minute:** (no limit)"

    trigger.update!(max_sessions_per_minute: 3)
    assert_includes @tool.call("id" => trigger.id), "- **Max Sessions/Minute:** 3"

    # A bursting trigger spawns nothing at all — say so, or a caller wondering
    # why it looks dead has no way to tell.
    trigger.update!(burst_active_until: 2.minutes.from_now)
    output = @tool.call("id" => trigger.id)
    assert_includes output, "BURSTING"
  end

  test "filters by condition type" do
    output = @tool.call("trigger_type" => "ao_event")

    assert_includes output, "### Needs Input Handler (ID: #{triggers(:ao_event_trigger).id})"
    assert_not_includes output, "### CI Failure Handler"
  end

  test "filters by status" do
    output = @tool.call("status" => "disabled")

    assert_includes output, "### Disabled Trigger"
    assert_not_includes output, "### CI Failure Handler"
  end

  # A one-time wake that failed to fire is parked as `failed` rather than deleted
  # (issue #76). An agent has to be able to find it and read why, or the record is
  # only half of a fix.
  test "filters by failed status and shows why the fire failed" do
    trigger = triggers(:enabled_slack_trigger)
    trigger.mark_failed(StandardError.new("Agent root 'gone' not found in catalog"))

    listing = @tool.call("status" => "failed")
    assert_includes listing, "### CI Failure Handler"
    assert_includes listing, "**Status:** failed"

    detail = @tool.call("id" => trigger.id)
    assert_includes detail, "- **Last Error:** StandardError: Agent root 'gone' not found in catalog"
    assert_includes detail, "action_trigger with action=toggle"
  end

  test "paginates" do
    output = @tool.call("per_page" => 1, "page" => 2)

    assert_match(/page 2 of #{Trigger.count}/, output)
    assert_equal 1, output.scan(/^### /).size
  end

  test "shows a trigger by id with conditions and recent sessions" do
    trigger = triggers(:enabled_slack_trigger)
    session = sessions(:active_session)
    session.update!(metadata: { "trigger_id" => trigger.id })

    output = @tool.call("id" => trigger.id)

    assert_includes output, "## Trigger: CI Failure Handler"
    assert_includes output, "- **Status:** enabled"
    assert_includes output, "- **Agent Root:** zimmer"
    assert_includes output, "- **Reuse Session:** No"
    assert_includes output, "- **MCP Servers:** slack-workspace"
    assert_includes output, "- **Goal:** PR is merged"
    assert_includes output, "- **Sessions Created:** 5"
    assert_includes output, "### Prompt Template"
    assert_match(/- \*\*\[id \d+\] slack\*\* — Slack: #eng-ci/, output)
    assert_includes output, '    "channel_id": "C0A6BF8T45R"'
    assert_includes output, "### Recent Sessions"
    assert_includes output, "- **##{session.id}**"
  end

  test "shows (none) for a trigger without mcp servers" do
    output = @tool.call("id" => triggers(:disabled_slack_trigger).id)

    assert_includes output, "- **MCP Servers:** (none)"
  end

  test "raises when the trigger does not exist" do
    error = assert_raises(Mcp::ToolError) { @tool.call("id" => 999_999) }

    assert_match(/Trigger not found: 999999/, error.message)
  end

  test "includes slack channels when asked" do
    channels = [ Channel.new("C123", "eng-ci", false, 12), Channel.new("C456", "secret", true, 3) ]

    SlackService.stub(:configured?, true) do
      SlackService.stub(:list_channels, channels) do
        output = @tool.call("include_channels" => true)

        assert_includes output, "## Available Slack Channels"
        assert_includes output, "- **#eng-ci** (C123) - 12 members"
        assert_includes output, "- **#secret** (C456) - 3 members [private]"
      end
    end
  end

  test "reports a slack failure inline instead of failing the listing" do
    SlackService.stub(:configured?, false) do
      output = @tool.call("include_channels" => true)

      assert_includes output, "### CI Failure Handler"
      assert_includes output, "*Could not fetch Slack channels: Slack is not configured*"
    end
  end

  test "a restricted connection only sees triggers on its allowed roots" do
    restricted = Mcp::Tools::SearchTriggers.new(
      context: Mcp::Context.new(tool_groups: "triggers", allowed_agent_roots: "pulsemcp")
    )

    output = restricted.call({})
    assert_includes output, "No triggers found.", "zimmer-root triggers must not leak to a pulsemcp-only connection"

    error = assert_raises(Mcp::ToolError) { restricted.call("id" => triggers(:enabled_slack_trigger).id) }
    assert_match(/not found/i, error.message)
  end

  test "the by-id view reports the catalog lists a trigger stamps onto its sessions" do
    trigger = triggers(:enabled_slack_trigger)
    trigger.update!(catalog_skills: [ "open-pr" ], catalog_hooks: [ "git-push-ci-reminder" ])

    output = @tool.call("id" => trigger.id)

    assert_includes output,
                    "- **Skills / Hooks / Plugins:** skills: open-pr | hooks: git-push-ci-reminder | " \
                    "plugins: (agent root defaults)",
                    "an empty list must not read as (none) — its sessions get the root's defaults"
  end

  test "the by-id view reports the reuse-only flags, and says what enqueue_messages off costs" do
    trigger = triggers(:weekly_schedule_trigger)

    output = @tool.call("id" => trigger.id)

    assert_includes output, "- **Enqueue Messages:** No — a fire onto a busy session is dropped"
    assert_includes output, "- **Resuscitate Archived:** No"
  end

  test "the reuse-only flags are omitted for a trigger that does not reuse its session" do
    output = @tool.call("id" => triggers(:enabled_slack_trigger).id)

    refute_includes output, "Enqueue Messages"
  end
end
