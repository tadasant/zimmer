# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Unit coverage for McpServerBackfill#detect_lost_mcp_servers, the guard that
# makes a narrowed MCP config loud instead of silent. See the concern's comments
# and the session-9563 incident for motivation.
class McpServerBackfillTest < ActiveSupport::TestCase
  # Minimal host exercising the concern in isolation, mirroring how
  # AgentSessionJob / UnarchiveSessionService include it.
  class Host
    include DatabaseRetry
    include McpServerBackfill
  end

  setup do
    # The AIR catalog isn't resolved in the test environment, so the model's
    # mcp_servers_must_exist_in_catalog validation would reject these names.
    ServersConfig.stubs(:exists?).returns(true)

    @host = Host.new
    @session = Session.create!(
      prompt: "Long-running task",
      git_root: "https://github.com/test/repo",
      branch: "main",
      mcp_servers: [ "appsignal-pulsemcp-prod" ]
    )
  end

  def with_status(status)
    @session.update!(custom_metadata: { "mcp_servers_status" => status })
    @session
  end

  test "returns lost servers when regenerated config drops a previously connected server" do
    with_status(
      "appsignal-pulsemcp-prod" => { "status" => "connected" },
      "digitalocean-tadasant" => { "status" => "connected" }
    )

    lost = @host.detect_lost_mcp_servers(
      @session,
      [ "agent-orchestrator-prod-self-session" ],
      context: "test"
    )

    assert_equal [ "digitalocean-tadasant" ], lost
  end

  test "returns empty when every previously connected server is still configured" do
    with_status("appsignal-pulsemcp-prod" => { "status" => "connected" })

    lost = @host.detect_lost_mcp_servers(@session, [], context: "test")

    assert_empty lost
  end

  test "counts auto-injected servers as still present" do
    with_status(
      "appsignal-pulsemcp-prod" => { "status" => "connected" },
      "agent-orchestrator-prod-self-session" => { "status" => "connected" }
    )

    lost = @host.detect_lost_mcp_servers(
      @session,
      [ "agent-orchestrator-prod-self-session" ],
      context: "test"
    )

    assert_empty lost,
      "an auto-injected server is part of the effective config and is not lost"
  end

  test "returns empty for a session that has never connected any MCP server" do
    lost = @host.detect_lost_mcp_servers(@session, [], context: "test")

    assert_empty lost,
      "a session with no mcp_servers_status history has no baseline to narrow from"
  end

  test "detecting a lost server logs at warn, not info" do
    with_status(
      "appsignal-pulsemcp-prod" => { "status" => "connected" },
      "digitalocean-tadasant" => { "status" => "connected" }
    )

    Rails.logger.expects(:warn).at_least_once.with { |msg| msg.to_s.include?("digitalocean-tadasant") }

    @host.detect_lost_mcp_servers(@session, [], context: "test")
  end

  # A user who deliberately removes a server through the UI/API must not then be
  # warned on every subsequent config regeneration that the server was "lost".
  # Session#forget_mcp_server_status! prunes the status history on those paths.
  test "does not report a deliberately removed server as lost" do
    with_status(
      "appsignal-pulsemcp-prod" => { "status" => "connected" },
      "digitalocean-tadasant" => { "status" => "connected" }
    )

    # Simulate PATCH /sessions/:id/mcp_servers removing digitalocean-tadasant.
    @session.update!(mcp_servers: [ "appsignal-pulsemcp-prod" ])
    @session.forget_mcp_server_status!([ "digitalocean-tadasant" ])

    lost = @host.detect_lost_mcp_servers(@session, [], context: "test")

    assert_empty lost,
      "an intentional removal is not an unexplained loss and must not warn"
  end

  test "forget_mcp_server_status! prunes only the named servers" do
    with_status(
      "appsignal-pulsemcp-prod" => { "status" => "connected" },
      "digitalocean-tadasant" => { "status" => "connected" }
    )

    @session.forget_mcp_server_status!([ "digitalocean-tadasant" ])

    assert_equal [ "appsignal-pulsemcp-prod" ],
      @session.reload.custom_metadata["mcp_servers_status"].keys
  end

  test "forget_mcp_server_status! is a no-op for an empty removal list" do
    with_status("appsignal-pulsemcp-prod" => { "status" => "connected" })

    assert_nothing_raised { @session.forget_mcp_server_status!([]) }
    assert_equal [ "appsignal-pulsemcp-prod" ],
      @session.reload.custom_metadata["mcp_servers_status"].keys
  end

  # The precise shape of the session-9563 regression: the session's mcp_servers
  # column has been narrowed to the agent root's single default, so the
  # regenerated config carries only that server plus the auto-injected
  # self-session server — exactly the two entries observed in production.
  test "flags the session-9563 narrowing to root default plus self-session" do
    @session.update!(mcp_servers: [ "appsignal-pulsemcp-prod" ])
    with_status(
      "appsignal-pulsemcp-prod" => { "status" => "connected" },
      "digitalocean-tadasant" => { "status" => "connected" },
      "tailscale-readwrite" => { "status" => "connected" }
    )

    lost = @host.detect_lost_mcp_servers(
      @session,
      [ "agent-orchestrator-prod-self-session" ],
      context: "follow_up"
    )

    assert_equal [ "digitalocean-tadasant", "tailscale-readwrite" ], lost.sort
  end
end
