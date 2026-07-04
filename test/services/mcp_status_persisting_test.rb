# frozen_string_literal: true

require "test_helper"

# Focused unit test for the shared McpStatusPersisting module, independent of
# either runtime's detector. The behavior under test is the LEVEL at which a
# detected (but not yet terminal) MCP connection failure is logged: it must be
# .info, because the failure is an intermediate attempt that AgentSessionJob
# retries with backoff. The .error that pages on-call is reserved for the
# terminal case in AgentSessionJob (see GitHub issues #3924 / #4109).
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
    @session.update!(mcp_servers: [ "appsignal-pulsemcp-prod" ])
    @logger = RecordingLogger.new
    @host = Host.new(@session, @logger)
  end

  test "a configured server failure is detected, escalated, but logged at .info (not .error)" do
    any_failed = @host.update_session_mcp_status(
      "appsignal-pulsemcp-prod" => { status: "failed", error: "Connection closed" }
    )

    assert any_failed, "configured server failure should escalate (any_failed)"

    @session.reload
    assert @session.custom_metadata["should_fail_session"], "should flag session for retry/failure handling"
    assert_equal "failed", @session.custom_metadata.dig("mcp_servers_status", "appsignal-pulsemcp-prod", "status")

    # The intermediate detection is logged at .info — NOT .error — so transient,
    # self-healing flaps don't trip the global prod-ERROR alert.
    detection_calls = @logger.calls.select { |c| c[:message].to_s.include?("detected as failed") }
    assert_equal 1, detection_calls.size, "expected exactly one detection log"
    assert_equal :info, detection_calls.first[:level], "detection must log at .info, not .error"

    assert_empty @logger.calls.select { |c| c[:level] == :error },
      "detection path must not emit any .error log (terminal .error lives in AgentSessionJob)"
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
