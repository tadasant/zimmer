# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Mcp::Tools::GetSystemHealthTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::GetSystemHealth.new(context: Mcp::Context.new(tool_groups: "health"))
    HealthMonitorService.any_instance.stubs(:full_health_report).returns(
      { overall_status: "healthy", session_health: { total_sessions: 3 } }
    )
  end

  test "renders the health report as a json block" do
    result = @tool.call({})

    assert_includes result, "## System Health Report"
    assert_includes result, "- **Environment:** test"
    assert_includes result, "- **Ruby Version:** #{RUBY_VERSION}"
    assert_includes result, "### Health Details"
    assert_includes result, '"overall_status": "healthy"'
    refute_includes result, "### CLI Status"
  end

  test "include_cli_status appends the cli report" do
    CliStatusService.stubs(:unauthenticated_count).returns(2)
    CliStatusService.stubs(:cached_report).returns({ tools: { claude: { authenticated: false } } })

    result = @tool.call("include_cli_status" => true)

    assert_includes result, "### CLI Status"
    assert_includes result, "- **Unauthenticated CLIs:** 2"
    assert_includes result, '"authenticated": false'
  end

  test "a failing cli report degrades to a note instead of losing the health report" do
    CliStatusService.stubs(:unauthenticated_count).raises(StandardError, "cache unavailable")

    result = @tool.call("include_cli_status" => true)

    assert_includes result, "## System Health Report"
    assert_includes result, "*Could not fetch CLI status: cache unavailable*"
  end
end
