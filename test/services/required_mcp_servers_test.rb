# frozen_string_literal: true

require "test_helper"

# The line this predicate draws is the whole of #1166's fix: on one side a lost
# server costs a capability and the session runs on (#521), on the other it costs
# the session its own lifecycle and there is nothing left for it to run for.
# Everything it cannot classify falls on the #521 side, because the cost of a
# wrong `true` is a killed session and the cost of a wrong `false` is the
# behaviour we already had.
class RequiredMcpServersTest < ActiveSupport::TestCase
  test "the injected self-session server is required" do
    assert RequiredMcpServers.required?(SelfSessionInjector::SELF_SESSION_SERVER_NAME)
  end

  test "the full-surface zimmer server is required" do
    # It is what a root with default_subagent_roots gets injected, and it carries
    # both the self_session group and start_session.
    assert RequiredMcpServers.required?(SelfSessionInjector::SUBAGENT_SERVER_NAME)
  end

  test "a zimmer server scoped away from self_session is not required" do
    # zimmer-fleet is `tool_groups=sessions,health_readonly`: losing it costs a
    # capability the agent can report and work around, which is exactly #521's case.
    refute RequiredMcpServers.required?("zimmer-fleet")
    refute RequiredMcpServers.required?("zimmer-gate-decisions")
    refute RequiredMcpServers.required?("zimmer-sessions")
  end

  test "a third-party server is never required, however important it looks" do
    refute RequiredMcpServers.required?("playwright-custom")
    refute RequiredMcpServers.required?("context7")
  end

  test "a nil or blank name is not required" do
    refute RequiredMcpServers.required?(nil)
    refute RequiredMcpServers.required?("")
    refute RequiredMcpServers.required?("   ")
  end

  test "an unknown zimmer-prefixed name is not required" do
    # No catalog row and not one of the two names the injector writes, so there is
    # no way to know what it is scoped to. Unknown falls on the #521 side.
    refute RequiredMcpServers.required?("zimmer-something-nobody-registered")
  end

  test "a catalog that will not resolve reports nothing as required" do
    # The consequence of `true` is a failed session, so a catalog blip must not be
    # able to produce one.
    ServersConfig.stub(:find, ->(_name) { raise AirCatalogService::CatalogError, "air resolve exploded" }) do
      refute RequiredMcpServers.required?(SelfSessionInjector::SELF_SESSION_SERVER_NAME)
    end
  end

  test "among returns the required subset in the order given" do
    assert_equal [ SelfSessionInjector::SELF_SESSION_SERVER_NAME ],
      RequiredMcpServers.among([ "context7", SelfSessionInjector::SELF_SESSION_SERVER_NAME, "zimmer-fleet" ])
    assert_empty RequiredMcpServers.among([ "context7" ])
    assert_empty RequiredMcpServers.among(nil)
  end

  # The predicate reads the catalog's URL where there is one, so a deployment that
  # scopes its own entries differently gets its own answer rather than Zimmer's.
  test "the answer follows the catalog entry's tool_groups" do
    scoped = ServersConfig::Server.new(
      SelfSessionInjector::SELF_SESSION_SERVER_NAME,
      "url" => "https://zimmer.example.com/mcp?tool_groups=sessions"
    )
    ServersConfig.stub(:find, ->(_name) { scoped }) do
      refute RequiredMcpServers.required?(SelfSessionInjector::SELF_SESSION_SERVER_NAME),
        "an entry scoped away from self_session carries none of the lifecycle tools"
    end

    lifecycle = ServersConfig::Server.new(
      "zimmer-fleet",
      "url" => "https://zimmer.example.com/mcp?tool_groups=sessions,self_session"
    )
    ServersConfig.stub(:find, ->(_name) { lifecycle }) do
      assert RequiredMcpServers.required?("zimmer-fleet"),
        "self_session among an entry's groups is what makes it required, whatever it is called"
    end
  end
end
