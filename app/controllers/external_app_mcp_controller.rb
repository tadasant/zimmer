# frozen_string_literal: true

# A Zimmer plugin's MCP endpoint:
#
#   POST /mcp/external_app      (X-API-Key: <plugin key>, or Authorization: Bearer <plugin key>)
#
# The same transport as McpController — stateless streamable HTTP, JSON
# responses — with a different credential and a fixed tool list. It accepts only
# a key with the `external_app` grant (ExternalAppAuthentication), and the
# connection sees exactly `list_triggers` and `invoke_trigger`
# (Mcp::ExternalAppContext). The query string is ignored, so `?tool_groups=` here
# changes nothing; and `/mcp` refuses this key, whatever it asks for.
class ExternalAppMcpController < McpController
  include ExternalAppAuthentication

  private

  def instructions
    "Zimmer plugin connection for \"#{current_external_app.name}\". It can list the Zimmer triggers " \
      "this credential may invoke (list_triggers) and invoke one with template variables " \
      "(invoke_trigger). Nothing else on this Zimmer instance is reachable with it."
  end

  def mcp_context
    @mcp_context ||= Mcp::ExternalAppContext.new(
      external_app: current_external_app,
      base_url: request.base_url,
      caller_fingerprint: HealthActionCooldown.fingerprint(api_key_from_request)
    )
  end
end
