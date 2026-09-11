# frozen_string_literal: true

# The four endpoints that make an MCP App fragment work on the session detail page.
#
#   GET  …/mcp_apps/:tool_call_id            the panel, as a lazy Turbo Frame
#   GET  …/mcp_apps/:tool_call_id/fragment   the fragment itself, sandboxed
#   POST …/mcp_apps/:tool_call_id/rpc        the view's tools/call and resources/read
#   POST …/mcp_apps/:tool_call_id/message    the view's ui/message, as an agent turn
#
# Every one of them resolves the same way and in the same order, which is the
# property that matters: the tool call is located in the transcript FIRST, and the
# MCP server is whatever that call named. Nothing here takes a server, a tool or a
# resource URI from the request. A crafted request can only ask about a tool call
# the agent really made, on a session the caller can already read, against a server
# an operator has opted in — or it resolves to nothing and gets a 404.
#
# `#fragment` is the one that serves third-party HTML, and McpApps::ContentSecurityPolicy
# is where the header it serves it under is built and argued for.
class McpAppsController < ApplicationController
  before_action :load_session
  # The cheapest gate first, and deliberately before the transcript is touched:
  # locating the tool call parses a window of the session's transcript, and a
  # deployment with MCP Apps switched off should not pay for that on a URL
  # anyone can request. The answer is a 404 either way.
  before_action :require_mcp_apps_enabled
  before_action :load_tool_call
  before_action :load_connection

  # GET /sessions/:session_id/mcp_apps/:tool_call_id
  def show
    @entry = tool_entry
    @fragment_error = nil

    if @entry&.view?
      begin
        # Read it now rather than letting the iframe discover the failure: a
        # fragment that cannot be fetched should render as a stated reason in
        # Zimmer's own chrome, not as a blank box. The read is cached, so the
        # iframe's own request costs nothing.
        McpApps::Fragment.for(@connection, @entry.resource_uri)
      rescue McpApps::Fragment::UnavailableError => e
        @fragment_error = e.message
      end
    end

    render layout: false
  end

  # GET /sessions/:session_id/mcp_apps/:tool_call_id/fragment
  def fragment
    entry = tool_entry
    return head(:not_found) unless entry&.view?

    fragment = McpApps::Fragment.for(@connection, entry.resource_uri)

    response.set_header("Content-Security-Policy", fragment.content_security_policy.header_value)
    response.set_header("X-Content-Type-Options", "nosniff")
    response.set_header("Referrer-Policy", "no-referrer")
    # Third-party HTML, rendered per session. Nothing about it should be held by
    # a shared cache, and nothing about it should survive a policy change.
    response.set_header("Cache-Control", "private, no-store")

    # `html_safe` on third-party HTML, deliberately and unavoidably: rendering a
    # view means serving the document the MCP server wrote, byte for byte. Nothing
    # here is escaping it — the CSP above and the sandbox on the embedding iframe
    # are what contain it, which is the whole of the security model.
    # rubocop:disable Rails/OutputSafety
    render html: fragment.html.html_safe, layout: false, content_type: "text/html"
    # rubocop:enable Rails/OutputSafety
  rescue McpApps::Fragment::UnavailableError => e
    Rails.logger.info("[mcp-apps] fragment unavailable for session #{@session.id}: #{e.message}")
    head :bad_gateway
  end

  # POST /sessions/:session_id/mcp_apps/:tool_call_id/rpc
  #
  # The view asked its host for something that is not a `ui/` method, so per the
  # spec the host forwards it to the MCP server. McpApps::Proxy decides what is
  # forwardable; this only carries the answer back in JSON-RPC's own shape, so the
  # broker in the browser can hand it to the view unchanged.
  def rpc
    return throttled(params[:method_name].to_s) unless McpApps::RequestThrottle.allow?(@session, "rpc")

    result = McpApps::Proxy.new(@connection).call(params[:method_name].to_s, rpc_params)

    if result.ok?
      render json: { result: result.result }
    else
      render json: { error: { code: result.code, message: result.message } }, status: :ok
    end
  end

  # POST /sessions/:session_id/mcp_apps/:tool_call_id/message
  def message
    unless McpApps::RequestThrottle.allow?(@session, "message")
      return render json: {
        status: "rejected",
        message: "This view is sending messages faster than Zimmer will pass them on."
      }, status: :too_many_requests
    end

    result = McpApps::WidgetMessage.deliver(
      session: @session,
      server_name: @tool_call.server_name,
      tool: @tool_call.tool,
      text: params[:text].to_s,
      kind: params[:kind].to_s
    )

    if result.ok?
      render json: { status: result.status, message: result.message }
    else
      render json: { status: result.status, message: result.message }, status: :unprocessable_entity
    end
  end

  private

  # JSON-RPC's own shape, so the broker in the browser can hand the view an error
  # it understands rather than a transport failure it cannot explain.
  def throttled(method_name)
    render json: {
      error: {
        code: McpApps::Proxy::INTERNAL_ERROR,
        message: "This view is making #{method_name.presence || 'requests'} calls faster than Zimmer will forward them."
      }
    }
  end

  def load_session
    @session = Session.find(params[:session_id])
  end

  def require_mcp_apps_enabled
    head :not_found unless McpApps::Policy.enabled?
  end

  # The transcript is the authority for what this URL is about. A tool_call_id
  # that is not at the claimed index, or that is not an MCP tool call on one of
  # this session's servers, is a 404 — there is nothing here to talk about.
  def load_tool_call
    @tool_call = McpApps::TranscriptToolCall.new(
      session: @session,
      tool_call_id: params[:tool_call_id],
      transcript_index: params[:transcript_index]
    )

    head :not_found unless @tool_call.found? && @tool_call.server_name.present?
  end

  def load_connection
    @connection = McpApps::ServerConnection.new(@session, @tool_call.server_name)
    head :not_found unless @connection.available?
  end

  def tool_entry
    McpApps::ToolIndex.new(@connection).entry(@tool_call.tool)
  rescue McpApps::Client::Error, McpApps::ServerConnection::UnavailableError => e
    Rails.logger.info("[mcp-apps] tools/list failed for #{@tool_call.server_name}: #{e.message}")
    nil
  end

  def rpc_params
    raw = params[:params]
    return raw.to_unsafe_h if raw.is_a?(ActionController::Parameters)

    raw.is_a?(Hash) ? raw : {}
  end
end
