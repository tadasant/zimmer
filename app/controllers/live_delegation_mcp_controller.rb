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
# or OAuth token is accepted here, the token is refused everywhere else, and it
# opens nothing once its conversation has ended or left the `gpt_live_claude`
# engine — the same conditions a delegation itself needs (Actions#delegate).
#
# Every call is one `tool_call` row on the voice-engine ledger, under the
# delegation's id, which is how ClaudeDelegate learns that Claude hung up.
class LiveDelegationMcpController < McpController
  skip_before_action :authenticate_api_key
  before_action :authenticate_delegation_token

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

  private

  def authenticate_delegation_token
    claims = LiveConversations::DelegationToken.verify(bearer_token)
    conversation = claims && LiveConversation.find_by(id: claims.live_conversation_id)
    if conversation&.active? && conversation.voice_engine == LiveConversations::VoiceEngine::GPT_LIVE
      @live_conversation = conversation
      @delegation_id = claims.delegation_id
    else
      reason = if claims.nil? then "invalid or expired delegation token"
      elsif conversation.nil? then "its conversation no longer exists"
      else "its conversation is no longer an active gpt_live_claude call"
      end
      Rails.logger.warn("[live.claude] #{request.request_method} #{request.path} refused from #{request.remote_ip}: #{reason}")
      SecurityTelemetry.record_auth_failure(:live_delegation_token, :invalid)
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
    bridge.realtime_tools.filter_map { |function| delegation_tool(bridge, function) }
  end

  # One function as an MCP tool, or nil when the SDK will not take its name or
  # schema (a catalog server's tool, say): one bad tool must not cost the run
  # every other one.
  def delegation_tool(bridge, function)
    name = function[:name]
    conversation = @live_conversation
    delegation_id = @delegation_id
    MCP::Tool.define(name: name, description: function[:description].to_s,
                     input_schema: function[:parameters].presence || { type: "object", properties: {} }) do |**arguments|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      outcome = bridge.execute(name, arguments.except(:server_context).deep_stringify_keys, call_id: "mcp_#{SecureRandom.hex(6)}")
      LiveDelegationMcpController.record_tool_call(conversation, delegation_id, name, outcome,
                                                   ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      MCP::Tool::Response.new([ { type: "text", text: outcome.output.to_s } ], error: outcome.error ? true : false)
    end
  rescue ArgumentError => e
    Rails.logger.warn("[live.claude] skipped tool #{name.to_s.truncate(64).inspect} for conversation=#{@live_conversation.id}: #{e.message.truncate(200)}")
    nil
  end
end
