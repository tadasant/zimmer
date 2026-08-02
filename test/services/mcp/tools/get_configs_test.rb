# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# get_configs is the agent's front door onto the catalog, and it reads through
# the same façades the session form does — the ones that rescue CatalogError to
# an empty array. So a broken catalog renders as "No MCP servers available",
# indistinguishable from a fresh install, and an agent goes on to call
# start_session against it. That is #112 on the agent side of the wall.
class Mcp::Tools::GetConfigsTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::GetConfigs.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  test "says nothing about catalog health when the catalog resolves" do
    AirCatalogService.stubs(:resolve_failure).returns(nil)

    result = @tool.call({})

    refute_includes result, "Catalog resolution is failing"
    assert_includes result, "## MCP Servers"
  end

  test "warns that empty lists are a resolution failure, not an empty catalog" do
    AirCatalogService.stubs(:resolve_failure).returns({ message: "boom", at: Time.utc(2026, 8, 1, 12, 0, 0) })
    AirCatalogService.stubs(:degraded?).returns(false)

    result = @tool.call({})

    assert_includes result, "Catalog resolution is failing"
    assert_includes result, "**because of the failure**"
    assert_includes result, "expect `start_session` to fail"
    assert_includes result, "2026-08-01T12:00:00Z"
  end

  test "warns that the lists are stale when a last-known-good catalog is being served" do
    AirCatalogService.stubs(:resolve_failure).returns({ message: "boom", at: Time.utc(2026, 8, 1, 12, 0, 0) })
    AirCatalogService.stubs(:degraded?).returns(true)
    AirCatalogService.stubs(:last_known_good_at).returns(Time.utc(2026, 8, 1, 10, 0, 0))

    result = @tool.call({})

    assert_includes result, "Catalog resolution is failing"
    assert_includes result, "last catalog that resolved successfully"
    assert_includes result, "2026-08-01T10:00:00Z"
  end

  # The session form prints `air resolve`'s stderr verbatim for an operator. That
  # process is handed AIR_GITHUB_TOKEN, so the same text must not travel to an
  # agent: the MCP surface carries the fact and its age, never the message.
  test "never echoes the resolve error onto the agent channel" do
    secret = "fatal: could not read Password for 'https://ghp_supersecrettoken@github.com'"
    AirCatalogService.stubs(:resolve_failure).returns({ message: secret, at: Time.current })
    AirCatalogService.stubs(:degraded?).returns(false)

    result = @tool.call({})

    assert_includes result, "Catalog resolution is failing"
    refute_includes result, secret
    refute_includes result, "ghp_supersecrettoken"
  end
end
