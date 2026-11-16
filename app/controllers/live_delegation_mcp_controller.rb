# frozen_string_literal: true

# The MCP endpoint a `gpt_live_claude` delegation's Claude Code process calls
# its tools through:
#
#   POST /live/delegation_mcp     (Authorization: Bearer <LiveConversations::DelegationToken>)
#
# The same transport as McpController — stateless streamable HTTP, JSON
# responses — with a different credential and a different tool list. The token
# names one Live conversation, and the tools are that conversation's ToolBridge
# functions (the ones a voice call has), executed and recorded exactly as a
# Realtime function call would be. Nothing else is reachable with it: no API key
# is accepted here, and the token is refused everywhere else.
#
# Every call is one `tool_call` row on the voice-engine ledger, as it was when
# Zimmer ran Claude's tool loop itself.
class LiveDelegationMcpController < McpController
  skip_before_action :authenticate_api_key
  before_action :authenticate_delegation_token

  private

  def authenticate_delegation_token
    claims = LiveConversations::DelegationToken.verify(bearer_token)
    @live_conversation = claims && LiveConversation.find_by(id: claims.live_conversation_id)
    if @live_conversation
      @delegation_id = claims.delegation_id
    else
      Rails.logger.warn("[live.claude] #{request.request_method} #{request.path} refused from #{request.remote_ip}: invalid or expired delegation token")
      render_api_error("Unauthorized", "Invalid or expired delegation token", status: :unauthorized)
    end
  end

  def oauth_access_tokens_accepted?
    false
  end

  def mcp_server
    MCP::Server.new(
      name: "zimmer-live-delegation",
      title: "Zimmer Live Mode",
      version: Mcp::SERVER_VERSION,
      instructions: "The Live Mode tools for this voice call: the same functions the voice model has.",
      tools: delegation_tools
    )
  end

  # ToolBridge's voice functions as MCP tools. Built per request, like the
  # server: the functions depend on the conversation's enabled servers.
  def delegation_tools
    bridge = LiveConversations::ToolBridge.new(@live_conversation, can_reattach: false, can_hang_up: true)
    conversation = @live_conversation
    delegation_id = @delegation_id
    bridge.realtime_tools.map do |function|
      name = function[:name]
      MCP::Tool.define(name: name, description: function[:description].to_s,
                       input_schema: function[:parameters].presence || { type: "object", properties: {} }) do |**arguments|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        outcome = bridge.execute(name, arguments.except(:server_context).deep_stringify_keys, call_id: "mcp_#{SecureRandom.hex(6)}")
        LiveDelegationMcpController.record_tool_call(conversation, delegation_id, name, outcome,
                                                     ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
        MCP::Tool::Response.new([ { type: "text", text: outcome.output.to_s } ], error: outcome.error ? true : false)
      end
    end
  end

  def self.record_tool_call(conversation, delegation_id, name, outcome, latency_ms)
    LiveUsageEvent.record!(
      engine: LiveConversations::VoiceEngine::GPT_LIVE, live_conversation: conversation,
      operation: "tool_call", vendor: "zimmer", model: name.to_s.truncate(120), count: 1, latency_ms: latency_ms,
      error: (outcome.output.to_s.truncate(250) if outcome.error),
      details: { delegation_id: delegation_id, call_id: outcome.turn&.call_id.to_s }
    )
  rescue ActiveRecord::ActiveRecordError => e
    # The ledger failing must not cost the call its tool result.
    ErrorReporter.report_exception(e, context: { source: "LiveDelegationMcpController", live_conversation_id: conversation.id })
  end
end
