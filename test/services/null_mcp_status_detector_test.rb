# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The Pi runtime's MCP status detector.
#
# The interesting method here is the one this class does NOT define. `poll` is a
# two-line stub and always has been; `update_session_mcp_status` is inherited
# from McpStatusPersisting, deliberately, because seeding the `pending`
# placeholders is the only MCP status a Pi session ever gets — Pi exposes no
# per-server signal, so a placeholder is the difference between a configured
# server rendering as "configured, state unknown" and vanishing from
# `mcp_servers_status` entirely (where every JSON consumer reads it as "not
# configured").
#
# That inherited method is what broke. This class included McpStatusPersisting
# without DatabaseRetry, so the module's `with_db_retry` call raised
# `NoMethodError` on every poll of the first Pi session to reach production.
# TranscriptPollerService rescues and logs, so the visible symptom was an ERROR
# log per poll and MCP status that never appeared — not a crash. These tests
# exercise the inherited path directly so a repeat fails here instead.
class NullMcpStatusDetectorTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @session.update!(agent_runtime: "pi", mcp_servers: [ "context7" ])
    @detector = NullMcpStatusDetector.new(@session, file_system: MockFileSystemAdapter.new)
  end

  test "poll reports no logs and no per-server statuses" do
    assert_equal({ logs: [], server_statuses: {} }, @detector.poll(transcript_content: "anything"))
  end

  test "update_session_mcp_status seeds a pending placeholder for every trackable server" do
    assert_nothing_raised { @detector.update_session_mcp_status({}) }

    persisted = @session.reload.custom_metadata["mcp_servers_status"]
    assert_not_nil persisted, "the persisting step must write mcp_servers_status"

    @session.all_mcp_servers.each do |server_name|
      assert_equal "pending", persisted.dig(server_name, "status"),
        "#{server_name} must be seeded as pending so it renders as configured-but-unknown"
    end
  end

  test "the persisting path has with_db_retry available to it" do
    assert @detector.respond_to?(:with_db_retry, true),
      "McpStatusPersisting calls with_db_retry; a detector that includes it without " \
      "DatabaseRetry raises NoMethodError on every poll (GlitchTip issue 85)"
  end

  test "a session with no trackable servers persists nothing rather than raising" do
    @session.update!(mcp_servers: [])
    @session.stubs(:all_mcp_servers).returns([])

    assert_nothing_raised { @detector.update_session_mcp_status({}) }
  end

  test "the poll-then-persist sequence TranscriptPollerService runs completes end to end" do
    result = @detector.poll(transcript_content: nil)

    assert_nothing_raised { @detector.update_session_mcp_status(result[:server_statuses]) }

    assert @session.reload.custom_metadata["mcp_servers_status"].any?,
      "the poll/persist pair must leave the session's MCP servers visible"
  end
end
