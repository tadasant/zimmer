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
    assert_includes output, "- **slack** — Slack: #eng-ci"
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
end
