# frozen_string_literal: true

module Webhooks
  # The MCP Events webhook receiver: `POST /webhooks/mcp_events/:token`, one URL per
  # McpEventWebhookSubscription (SEP-3415 @ b08e4f9, "Webhook event delivery").
  #
  # In production the path sits behind a Cloudflare Access service-token policy of its own, which
  # the delivering server satisfies with CF-Access-Client-Id / -Secret headers. Nothing here reads
  # those: the Standard Webhooks HMAC is checked on every request regardless, and it is what says
  # which subscription a delivery belongs to. The receiver is written to be safe even if the Access
  # policy were ever opened up. That is why every refusal here looks the same. An unknown token, a bad or stale
  # signature and a missing header all get an empty 401, with an HMAC computed either way, so a
  # caller cannot tell a real subscription URL from a made-up one. A caller is also rate-limited per
  # address before any of that, so it cannot make the action do unbounded HMAC work.
  #
  # Three kinds of body arrive, all signed and all checked before anything parses them:
  #
  #   verification  `{"type":"verification","challenge":...}` — the server checking that this
  #                 endpoint wants its deliveries, while Zimmer's `events/subscribe` waits on it.
  #                 Answered by echoing the challenge. This is the verification method Zimmer
  #                 supports, from the SEP's four.
  #   gap / terminated  control envelopes: a fresh cursor after skipped events, or the server
  #                 ending the subscription. Recorded on the row.
  #   an event      an EventOccurrence. Deduplicated on `webhook-id` in WebhookDelivery, recorded,
  #                 and handed to McpEventWebhookJob in the same transaction, then acknowledged.
  #                 The job fires through the poller's claims, so an event also seen by a poll
  #                 fires once.
  #
  # See Webhooks::BaseController for the order every check runs in.
  class McpEventsController < BaseController
    # Requests one address may make in RATE_LIMIT_WINDOW, counted before the signature is checked.
    # A gateway delivers every subscription's events from a few addresses, so this is generous; it
    # is a brake on someone hammering the public path, not a quota.
    RATE_LIMIT = 600
    RATE_LIMIT_WINDOW = 1.minute

    # A well-formed secret nobody holds, so an unknown token still pays for an HMAC (a known one
    # also pays for decrypting its secret, which with a 192-bit token says nothing useful).
    DECOY_SECRET = "whsec_#{Base64.strict_encode64('zimmer-mcp-events-decoy-secret!!')}".freeze

    # How long after a `terminated` envelope the sweep subscribes again.
    TERMINATION_RETRY = 10.minutes

    # The SEP's routing header, carrying the server's subscription id.
    SUBSCRIPTION_ID_HEADER = "X-MCP-Subscription-Id"

    def create
      return head(:too_many_requests) if rate_limited?
      return refuse(413, "body over #{MAX_BODY_BYTES} bytes") if body_too_large?

      subscription = McpEventWebhookSubscription.find_by(token: params[:token].to_s)
      verification = StandardWebhooksSignature.verify(
        secret: subscription&.secret || DECOY_SECRET,
        body: raw_body,
        message_id: request.headers["webhook-id"],
        timestamp: request.headers["webhook-timestamp"],
        signature: request.headers["webhook-signature"]
      )
      return refuse(:unauthorized, "unknown subscription token") if subscription.nil?
      return refuse(:unauthorized, "subscription #{subscription.id}: #{verification.reason}") unless verification.valid?

      payload = parse_payload
      return refuse(:bad_request, "subscription #{subscription.id}: body is not a JSON object") unless payload.is_a?(Hash)

      remote_id = request.headers[SUBSCRIPTION_ID_HEADER].to_s.presence
      case payload["type"]
      when "verification" then answer_challenge(subscription, payload, remote_id)
      when "gap" then accept_gap(subscription, payload, remote_id)
      when "terminated" then accept_termination(subscription, payload, remote_id)
      when nil then accept_event(subscription, payload, remote_id)
      else
        # A control envelope a later revision adds. Acknowledged, so the server does not retry it.
        subscription.note_signed_request!(remote_id: remote_id)
        head :ok
      end
    end

    private

    def answer_challenge(subscription, payload, remote_id)
      challenge = payload["challenge"]
      return refuse(:bad_request, "subscription #{subscription.id}: verification with no challenge") unless challenge.is_a?(String) && challenge.present? && challenge.length <= 1024

      subscription.note_signed_request!(remote_id: remote_id)
      Rails.logger.info("[Webhooks::McpEventsController] Answered the endpoint verification for subscription #{subscription.id}")
      render json: { challenge: challenge }
    end

    def accept_gap(subscription, payload, remote_id)
      subscription.note_signed_request!(remote_id: remote_id, cursor: cursor_from(payload))
      Rails.logger.warn("[Webhooks::McpEventsController] #{subscription.server} reported a gap on subscription #{subscription.id} " \
                        "(#{subscription.event_name}); the condition's poll catches up on what it can")
      head :ok
    end

    def accept_termination(subscription, payload, remote_id)
      error = payload["error"].is_a?(Hash) ? payload["error"] : {}
      code_name = McpEvents.error_name(error["code"]) || "unknown"
      subscription.note_signed_request!(remote_id: remote_id)
      # The subscription no longer exists on the server; the next sweep subscribes afresh, which
      # fails the same way if the cause still holds.
      # Ten minutes before subscribing again, so a server that terminates every subscription it
      # grants is asked six times an hour rather than sixty.
      subscription.update_columns(state: "pending", refresh_before: nil,
                                  last_error: "#{McpEventSubscriptionsJob::TERMINATED_PREFIX} (#{code_name})",
                                  next_attempt_at: TERMINATION_RETRY.from_now, updated_at: Time.current)
      Rails.logger.warn("[Webhooks::McpEventsController] #{subscription.server} terminated subscription #{subscription.id} (#{code_name})")
      head :ok
    end

    def accept_event(subscription, payload, remote_id)
      occurrence = McpEvents::Client.occurrence_from(payload)
      return refuse(:bad_request, "subscription #{subscription.id}: not an event occurrence") if occurrence.nil?

      # The condition was edited, disabled or deleted, and the sweep has not unsubscribed yet. 410
      # is the SEP's "do not retry this delivery", and it leaves the subscription alone.
      unless subscription.live?
        subscription.note_signed_request!(remote_id: remote_id)
        return head(:gone)
      end

      first = ActiveRecord::Base.transaction do
        recorded = WebhookDelivery.record_first!(
          source: "mcp_events",
          delivery_id: "#{subscription.id}:#{request.headers['webhook-id']}",
          event_type: subscription.event_name.truncate(255)
        )
        McpEventWebhookJob.perform_later(subscription.id, payload.slice("eventId", "name", "timestamp", "data")) if recorded
        recorded
      end
      subscription.note_signed_request!(remote_id: remote_id, cursor: cursor_from(payload), delivered: true)

      Rails.logger.info("[Webhooks::McpEventsController] Redelivery of #{request.headers['webhook-id']} on subscription #{subscription.id}; already accepted") unless first
      render json: { ok: true }
    end

    # The cursor to persist, or :unchanged. By the SEP an absent cursor means null, but persisting
    # null would make the next refresh "start from now", so only an explicit null clears the stored
    # one; a value Zimmer would not store (not a string, or over 4 KB) leaves it as it was.
    def cursor_from(payload)
      return :unchanged unless payload.key?("cursor")

      value = payload["cursor"]
      return nil if value.nil?
      return :unchanged unless value.is_a?(String) && value.length <= 4096

      value.presence
    end

    # One counter per client address per window, as Api::V1::QuickRouterController keeps. A store
    # that cannot count returns nil and the request goes through: the signature is the boundary,
    # and this is the brake in front of it.
    def rate_limited?
      count = Rails.cache.increment("mcp_events_webhook:rate:#{request.remote_ip}", 1, expires_in: RATE_LIMIT_WINDOW)
      return false if count.nil? || count <= RATE_LIMIT

      Rails.logger.warn("[Webhooks::McpEventsController] Rate-limited #{request.remote_ip}")
      true
    end

    # An empty body whatever went wrong; the reason goes to the log only.
    def refuse(status, reason)
      Rails.logger.warn("[Webhooks] Rejected an MCP events delivery from #{request.remote_ip}: #{reason}")
      head status
    end
  end
end
