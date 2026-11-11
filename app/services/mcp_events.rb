# frozen_string_literal: true

# Zimmer as a CLIENT of the MCP Events extension: the draft SEP-3415, which lets a server publish
# typed events a client can poll, stream or receive by webhook.
#
# Zimmer speaks two of the three delivery modes, only from Rails and never from an agent session,
# with the credentials a session would get for the server:
#
#   poll     McpEventTriggerPollerJob calls `events/poll` and fires `mcp_event` trigger conditions.
#            It always runs, as the catch-up path that keeps delivery at-least-once.
#   webhook  McpEventSubscriptionsJob calls `events/subscribe` for a condition whose event type
#            offers it, and Webhooks::McpEventsController receives the signed POSTs and fires the
#            same conditions through the same claims (McpEvents::Firing), so an event that arrives
#            both ways fires once.
#
# Push (`events/stream`) needs a long-lived listener Zimmer does not run. Every path on the
# production host is behind Cloudflare Access, so the webhook receiver's path needs an Access bypass
# rule, with the HMAC as its real authentication (see limitations.md and triggers.md).
#
# The extension is an unmerged draft. SPEC_REVISION is the head commit this implementation was
# written against; docs/src/content/docs/sessions/mcp-events-spec-pin.md records what it covers and
# where it deliberately deviates. Bring both up to date whenever the SEP moves.
module McpEvents
  # The extension's identifier, under `capabilities.extensions` in what a server declares.
  EXTENSION_ID = "io.modelcontextprotocol/events"

  # The SEP-3415 head commit this implementation follows.
  SPEC_REVISION = "b08e4f9dd684f39d846d94089487fbeb28e666f5"

  # The extension's error codes, by name. The SEP calls the numbers provisional, so nothing else
  # names them.
  ERROR_CODES = {
    -32602 => :invalid_params,
    -32023 => :not_found,
    -32024 => :forbidden,
    -32025 => :resource_exhausted,
    -32026 => :unsupported,
    -32027 => :callback_endpoint_error
  }.freeze

  # The `lastError` / `CallbackEndpointError` `data.reason` categories. A server's value is shown
  # only if it is one of these, so a server cannot put arbitrary text in the trigger UI.
  DELIVERY_ERROR_CATEGORIES = %w[connection_refused timeout tls_error http_4xx http_5xx challenge_failed].freeze

  # The shape a server's event name may take before Zimmer stores it or sends it in a header:
  # printable ASCII with no spaces, which covers a gateway's `<slug>__<name>` prefixing.
  NAME_FORMAT = /\A[A-Za-z0-9._:\/-]{1,200}\z/

  # The base URL a server can POST webhook deliveries to — Zimmer's public base URL — or nil when
  # there is none: a placeholder (the deploy never set it) or a plain-http one (a local server; the
  # SEP requires `https` callbacks). With nil, no condition subscribes and polling carries
  # everything.
  #
  # @return [String, nil]
  def self.webhook_base_url
    url = AppUrl.base_url
    return nil if AppUrl.placeholder?(url) || !url.start_with?("https://")

    url
  end

  # @param code [Integer, nil] a JSON-RPC error code
  # @return [Symbol, nil] the extension's name for it
  def self.error_name(code)
    ERROR_CODES[code]
  end
end
