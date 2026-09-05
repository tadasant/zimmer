# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Focused unit test for the shared McpStatusPersisting module, independent of
# either runtime's detector. The behavior under test is the LEVEL at which a
# detected (but not yet terminal) MCP connection failure is logged: it must be
# .info, because the failure is an intermediate attempt that AgentSessionJob
# retries with backoff. The .error that pages on-call is reserved for the
# terminal case in AgentSessionJob (see GitHub issues pulsemcp/pulsemcp#3924 /
# pulsemcp/pulsemcp#4109).
class McpStatusPersistingTest < ActiveSupport::TestCase
  # Records every log call so we can assert the level a message was logged at.
  class RecordingLogger
    attr_reader :calls

    def initialize
      @calls = []
    end

    def info(message, context = {})
      @calls << { level: :info, message: message, context: context }
    end

    def warn(message, context = {})
      @calls << { level: :warn, message: message, context: context }
    end

    def error(message, context = {})
      @calls << { level: :error, message: message, context: context }
    end

    def level_for(message_fragment)
      @calls.find { |c| c[:message].to_s.include?(message_fragment) }&.fetch(:level)
    end
  end

  # Minimal host mixing in the module with an injectable session + logger, the
  # two collaborators the module requires (plus with_db_retry from DatabaseRetry).
  class Host
    include DatabaseRetry
    include McpStatusPersisting

    def initialize(session, logger)
      @session = session
      @logger = logger
    end
  end

  setup do
    @session = sessions(:running)
    @session.update!(mcp_servers: [ "context7" ])
    @logger = RecordingLogger.new
    @host = Host.new(@session, @logger)
  end

  test "a configured server failure is detected, escalated, but logged at .info (not .error)" do
    any_failed = @host.update_session_mcp_status(
      "context7" => { status: "failed", error: "Connection closed" }
    )

    assert any_failed, "configured server failure should escalate (any_failed)"

    @session.reload
    assert @session.custom_metadata["should_fail_session"], "should flag session for retry/failure handling"
    assert_equal "failed", @session.custom_metadata.dig("mcp_servers_status", "context7", "status")

    # The intermediate detection is logged at .info — NOT .error — so transient,
    # self-healing flaps don't trip the global prod-ERROR alert.
    detection_calls = @logger.calls.select { |c| c[:message].to_s.include?("detected as failed") }
    assert_equal 1, detection_calls.size, "expected exactly one detection log"
    assert_equal :info, detection_calls.first[:level], "detection must log at .info, not .error"

    assert_empty @logger.calls.select { |c| c[:level] == :error },
      "detection path must not emit any .error log (terminal .error lives in AgentSessionJob)"
  end

  # --- placeholder seeding (issue #196) --------------------------------------

  # A server whose process died before it ever created a log directory produces
  # no status at all. Skipping it left it absent from mcp_servers_status, and
  # absent reads as "not configured" everywhere — the API, the MCP tools, the
  # session row. Configured-and-broken is the truth; pending is how it is said.
  test "a server the detector said nothing about is seeded pending, not dropped" do
    @session.update!(mcp_servers: [ "context7", "playwright-custom" ])

    @host.update_session_mcp_status("context7" => { status: "connected" })

    @session.reload
    statuses = @session.custom_metadata["mcp_servers_status"]
    assert_equal "connected", statuses.dig("context7", "status")
    assert_equal "pending", statuses.dig("playwright-custom", "status"),
      "a server with no detected status is still listed"
  end

  # The failure this fixes is exactly the single-server session whose only server
  # never got far enough to log: the detector returns {} and the server used to
  # vanish entirely.
  test "an empty status hash still lists every trackable server" do
    any_failed = @host.update_session_mcp_status({})

    refute any_failed
    @session.reload
    assert_equal "pending", @session.custom_metadata.dig("mcp_servers_status", "context7", "status")
  end

  test "a session with no trackable servers writes nothing" do
    @session.update!(mcp_servers: [], custom_metadata: {})

    refute @host.update_session_mcp_status({})

    @session.reload
    assert_nil @session.custom_metadata["mcp_servers_status"]
  end

  # The placeholder is a floor, never a correction: a real status already on the
  # record survives a later poll that has nothing to say about that server.
  test "the placeholder never overwrites a status already recorded" do
    @host.update_session_mcp_status("context7" => { status: "failed", error: "Connection closed" })

    @host.update_session_mcp_status({})

    @session.reload
    assert_equal "failed", @session.custom_metadata.dig("mcp_servers_status", "context7", "status")
    assert_equal "Connection closed", @session.custom_metadata.dig("mcp_servers_status", "context7", "error")
  end

  # Polls are frequent and mostly say nothing new. An unconditional write would
  # re-run Session's full validation set — including the AIR-catalog-backed
  # artifact validators — several times a minute per live session, for no write.
  test "a poll with nothing new to say does not write the session at all" do
    @host.update_session_mcp_status("context7" => { status: "connected" })

    Session.any_instance.expects(:update!).never

    @host.update_session_mcp_status("context7" => { status: "connected" })
  end

  # And it is a floor in the other direction too: seeding pending first must not
  # stop the real status from landing when the detector finally sees the server.
  test "a seeded placeholder is replaced by the real status when it arrives" do
    @host.update_session_mcp_status({})
    assert_equal "pending", @session.reload.custom_metadata.dig("mcp_servers_status", "context7", "status")

    any_failed = @host.update_session_mcp_status("context7" => { status: "failed", error: "boom" })

    assert any_failed, "escalation still fires after a placeholder was seeded"
    @session.reload
    assert_equal "failed", @session.custom_metadata.dig("mcp_servers_status", "context7", "status")
  end

  # --- the same floor, applied before any detector runs (issue #465) ----------
  #
  # Session#seed_mcp_servers_status_floor! is the other half of the floor above:
  # the detector-side seeding only happens once a poll reaches this module, and
  # the paths that run before that (a resume, the spawn itself) need the same
  # guarantee with the same semantics. These assert they really are the same
  # semantics, so the two cannot drift.

  test "the floor lists every trackable server, user-selected and injected alike" do
    @session.update!(
      mcp_servers: [ "context7" ],
      custom_metadata: { "injected_mcp_servers" => [ "playwright-custom" ] }
    )

    assert @session.seed_mcp_servers_status_floor!

    statuses = @session.reload.custom_metadata["mcp_servers_status"]
    assert_equal({ "context7" => { "status" => "pending" }, "playwright-custom" => { "status" => "pending" } },
      statuses)
  end

  test "the floor never overwrites a status already recorded" do
    @host.update_session_mcp_status("context7" => { status: "connected", connected_at: "2026-09-04T10:00:00Z" })
    # A second server arrives after that status was recorded, so the floor has
    # something to add and must add only that.
    @session.reload.update!(mcp_servers: [ "context7", "playwright-custom" ])

    assert @session.seed_mcp_servers_status_floor!

    statuses = @session.reload.custom_metadata["mcp_servers_status"]
    assert_equal "connected", statuses.dig("context7", "status")
    assert_equal "2026-09-04T10:00:00Z", statuses.dig("context7", "connected_at")
    assert_equal "pending", statuses.dig("playwright-custom", "status")
  end

  test "the floor writes nothing when every trackable server already has an entry" do
    @host.update_session_mcp_status("context7" => { status: "connected" })
    @session.reload

    Session.any_instance.expects(:merge_custom_metadata!).never

    refute @session.seed_mcp_servers_status_floor!
  end

  test "the floor writes nothing for a session with no trackable servers" do
    @session.update!(mcp_servers: [], custom_metadata: {})

    refute @session.seed_mcp_servers_status_floor!

    assert_nil @session.reload.custom_metadata["mcp_servers_status"]
  end

  # --- retiring a degraded server that came back (issue #521) -----------------

  test "a degraded server that reconnects has its write-off retired" do
    @session.update!(metadata: (@session.metadata || {}).merge(
      "mcp_degraded_servers" => [
        { "name" => "context7", "error" => "Connection closed", "degraded_at" => "2026-08-23T15:20:54Z" }
      ]
    ))

    @host.update_session_mcp_status("context7" => { status: "connected", connected_at: "2026-08-23T16:00:00Z" })

    @session.reload
    assert_empty @session.degraded_mcp_servers,
      "a server that connected is not unavailable, and the agent's prompt must stop saying it is"
    assert_nil @session.metadata["mcp_degraded_servers"]
    assert @logger.calls.any? { |c| c[:message].to_s.include?("reconnected") }
  end

  test "reconnecting one degraded server leaves the others written off" do
    @session.update!(
      mcp_servers: [ "context7", "linear" ],
      metadata: (@session.metadata || {}).merge(
        "mcp_degraded_servers" => [
          { "name" => "context7", "error" => "Connection closed" },
          { "name" => "linear", "error" => "Connection closed" }
        ]
      )
    )

    @host.update_session_mcp_status(
      "context7" => { status: "connected", connected_at: "2026-08-23T16:00:00Z" },
      "linear" => { status: "failed", error: "Connection closed" }
    )

    @session.reload
    assert_equal [ "linear" ], @session.degraded_mcp_server_names
  end

  test "a connected server that was never degraded writes nothing to the degraded record" do
    @host.update_session_mcp_status("context7" => { status: "connected", connected_at: "2026-08-23T16:00:00Z" })

    @session.reload
    assert_nil @session.metadata["mcp_degraded_servers"]
    assert_empty @logger.calls.select { |c| c[:message].to_s.include?("reconnected") }
  end

  test "an injected (non-configured) server failure neither escalates nor logs" do
    @session.update!(mcp_servers: [], custom_metadata: { "injected_mcp_servers" => [ "playwright-custom" ] })

    any_failed = @host.update_session_mcp_status(
      "playwright-custom" => { status: "failed", error: "Connection closed" }
    )

    refute any_failed
    @session.reload
    assert_nil @session.custom_metadata["should_fail_session"]
    # Status is still recorded for the UI, but no detection log fires.
    assert_equal "failed", @session.custom_metadata.dig("mcp_servers_status", "playwright-custom", "status")
    assert_empty @logger.calls, "injected-server failure must not log a detection message"
  end
end
