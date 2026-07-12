# frozen_string_literal: true

require "test_helper"

class Mcp::RegistryTest < ActiveSupport::TestCase
  test "no groups means every base group (the full read+write surface)" do
    assert_equal Mcp::Registry::BASE_GROUPS, Mcp::Registry.parse_groups(nil)
    assert_equal Mcp::Registry::BASE_GROUPS, Mcp::Registry.parse_groups("")
    assert_equal Mcp::Registry::ALL_TOOLS.size, Mcp::Registry.tools_for(Mcp::Registry.parse_groups(nil)).size
  end

  test "unknown groups are dropped, known ones kept" do
    assert_equal [ "sessions" ], Mcp::Registry.parse_groups("sessions,not_a_group")
  end

  test "self_session exposes exactly the self-management surface" do
    names = Mcp::Registry.tools_for([ "self_session" ]).map(&:tool_name)

    assert_equal %w[get_session get_configs action_session send_push_notification wake_me_up_later
                    wake_me_up_when_session_changes_state].sort, names.sort
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

    assert_equal %w[get_notifications get_system_health action_health].sort, names.sort
  end

  test "every registered tool class exists and declares a unique name" do
    names = Mcp::Registry::ALL_TOOLS.map { |d| d.klass.constantize.tool_name }

    assert_equal names.uniq.size, names.size, "duplicate tool names: #{names.tally.select { |_, c| c > 1 }.keys}"
    assert_equal 18, names.size
  end
end
