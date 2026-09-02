# frozen_string_literal: true

require "test_helper"

class Mcp::RegistryTest < ActiveSupport::TestCase
  test "no groups means every base group, and nothing outside them" do
    assert_equal Mcp::Registry::BASE_GROUPS, Mcp::Registry.parse_groups(nil)
    assert_equal Mcp::Registry::BASE_GROUPS, Mcp::Registry.parse_groups("")

    default_surface = Mcp::Registry.tools_for(Mcp::Registry.parse_groups(nil))
    opt_in = Mcp::Registry::ALL_TOOLS.count { |d| Mcp::Registry::OPT_IN_GROUPS.include?(d.group) }

    assert_operator opt_in, :>, 0, "no opt-in tools left — this test proves nothing"
    assert_equal Mcp::Registry::ALL_TOOLS.size - opt_in, default_surface.size
  end

  # The point of an opt-in group: valid and addressable, never handed out by
  # default. `gate_decisions` is the first one, and the reason is least privilege
  # — the unscoped `/mcp` surface is the broadest reach in the deployment, so a
  # write to the gates' own calibration memory must not ride along on it.
  test "an opt-in group is valid and addressable but outside the default set" do
    Mcp::Registry::OPT_IN_GROUPS.each do |group|
      assert_includes Mcp::Registry::VALID_GROUPS, group
      assert_includes Mcp::Registry::VALID_GROUPS, "#{group}_readonly"
      assert_not_includes Mcp::Registry::BASE_GROUPS, group
      assert_equal [ group ], Mcp::Registry.parse_groups(group)
    end
  end

  test "unknown groups are dropped, known ones kept" do
    assert_equal [ "sessions" ], Mcp::Registry.parse_groups("sessions,not_a_group")
  end

  test "self_session exposes exactly the self-management surface" do
    names = Mcp::Registry.tools_for([ "self_session" ]).map(&:tool_name)

    assert_equal %w[get_session get_session_provenance get_configs action_session send_push_notification
                    wake_me_up_later wake_me_up_when_session_changes_state].sort, names.sort
  end

  test "self_session gets the restricted action_session variant" do
    klass = Mcp::Registry.tools_for([ "self_session" ]).find { |t| t.tool_name == "action_session" }
    assert_equal Mcp::Tools::SelfSessionActionSession, klass
  end

  test "the sessions group gets the unrestricted action_session, even alongside self_session" do
    klass = Mcp::Registry.tools_for([ "sessions", "self_session" ]).find { |t| t.tool_name == "action_session" }
    assert_equal Mcp::Tools::ActionSession, klass
  end

  test "a readonly group drops write tools" do
    names = Mcp::Registry.tools_for([ "triggers_readonly" ]).map(&:tool_name)

    assert_equal [ "search_triggers" ], names
  end

  test "groups compose" do
    names = Mcp::Registry.tools_for([ "health", "notifications_readonly" ]).map(&:tool_name)

    assert_equal %w[get_notifications get_system_health action_health get_spot_policy action_spot_policy get_costs].sort, names.sort
  end

  test "every registered tool class exists and declares a unique name" do
    names = Mcp::Registry::ALL_TOOLS.map { |d| d.klass.constantize.tool_name }

    assert_equal names.uniq.size, names.size, "duplicate tool names: #{names.tally.select { |_, c| c > 1 }.keys}"
    assert_equal 29, names.size
  end

  # The work backlog is read by a job that spawns sessions from it with no
  # human in the loop, so who may write to it matters as much as it does for
  # the gate ledger — and the group is opt-in for the same reason.
  test "the work_backlog group carries the three backlog tools, nothing else reaches them, and readonly drops the writes" do
    backlog_tools = %w[get_work_backlog append_work_backlog_item pull_work_backlog_items]

    assert_equal backlog_tools.sort, Mcp::Registry.tools_for([ "work_backlog" ]).map(&:tool_name).sort
    assert_equal [ "get_work_backlog" ], Mcp::Registry.tools_for([ "work_backlog_readonly" ]).map(&:tool_name)

    [ [ "sessions" ], [ "self_session" ], [ "sessions", "self_session" ], [ "health" ], [ "triggers" ],
      [ "notifications" ], [ "gate_decisions" ], Mcp::Registry.parse_groups(nil) ].each do |groups|
      names = Mcp::Registry.tools_for(groups).map(&:tool_name)
      assert_empty names & backlog_tools,
                   "#{groups.join(',')} must not reach the work backlog, but reaches #{(names & backlog_tools).join(', ')}"
    end
  end

  # The gate decision ledger's whole trustworthiness rests on this group being
  # separate AND opt-in. Folded into `sessions`, every session carrying
  # `zimmer-sessions` could write gate ratings; left in BASE_GROUPS, every
  # session holding the full `zimmer` server could — and a ledger anything can
  # write is not evidence.
  test "the unscoped surface does not carry the ledger tools, and naming the group does" do
    unscoped = Mcp::Registry.tools_for(Mcp::Registry.parse_groups(nil)).map(&:tool_name)

    assert_not_includes unscoped, "record_gate_decision"
    assert_not_includes unscoped, "search_gate_decisions"
    assert_not_includes unscoped, "get_gate_decision_feedback"
    assert_includes unscoped, "start_session", "the rest of the default surface is unchanged"

    named = Mcp::Registry.tools_for(Mcp::Registry.parse_groups("gate_decisions")).map(&:tool_name)

    assert_includes named, "record_gate_decision"
    assert_includes named, "search_gate_decisions"
    assert_includes named, "get_gate_decision_feedback"
  end

  test "the gate_decisions group carries the ledger tools and nothing else does" do
    assert_equal %w[search_gate_decisions get_gate_decision_feedback record_gate_decision].sort,
                 Mcp::Registry.tools_for([ "gate_decisions" ]).map(&:tool_name).sort
  end

  test "a session scoped to sessions or self_session cannot reach the ledger tools" do
    ledger_tools = %w[search_gate_decisions get_gate_decision_feedback record_gate_decision]

    [ [ "sessions" ], [ "self_session" ], [ "sessions", "self_session" ],
      [ "health" ], [ "triggers" ], [ "notifications" ],
      Mcp::Registry.parse_groups(nil) ].each do |groups|
      names = Mcp::Registry.tools_for(groups).map(&:tool_name)
      assert_empty names & ledger_tools,
                   "#{groups.join(',')} must not reach the gate decision ledger, but reaches #{(names & ledger_tools).join(', ')}"
    end
  end

  test "gate_decisions_readonly can read the ledger but not write to it" do
    names = Mcp::Registry.tools_for([ "gate_decisions_readonly" ]).map(&:tool_name)

    assert_equal %w[search_gate_decisions get_gate_decision_feedback].sort, names.sort
    assert_not_includes names, "record_gate_decision"
  end

  # There is no machine path to human feedback, on any group, by any name. The
  # field's entire value is that a machine did not write it, so the assertion is
  # over the whole surface rather than over one group.
  test "no MCP tool anywhere can write human feedback" do
    writers = Mcp::Registry::ALL_TOOLS.select(&:write?).map { |d| d.klass.constantize }

    writers.each do |klass|
      schema = klass.input_schema.to_h.deep_stringify_keys
      properties = schema.dig("properties") || {}
      assert_not_includes properties.keys, "human_feedback",
                          "#{klass.tool_name} accepts a human_feedback parameter"
      assert_not_includes properties.keys, "feedback",
                          "#{klass.tool_name} accepts a feedback parameter"
    end

    assert_empty Mcp::Registry::ALL_TOOLS.map { |d| d.klass }.grep(/Feedback/).select { |k|
      Mcp::Registry::ALL_TOOLS.find { |d| d.klass == k }.write?
    }, "a feedback tool is registered as a write tool"
  end
end
