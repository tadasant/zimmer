# frozen_string_literal: true

module Webhooks
  # Slack's Events API request URL: `POST /webhooks/slack`.
  #
  # Two kinds of signed request arrive here. `url_verification` is the one-time handshake when the
  # request URL is saved in the Slack app's settings, answered by echoing its `challenge`.
  # `event_callback` carries one event, which is recorded under its `event_id` and handed to
  # SlackEventJob — Slack wants an answer within three seconds and firing a trigger makes Slack
  # API calls, so nothing is fired on this request.
  #
  # See Webhooks::BaseController for the order every check runs in.
  class SlackController < BaseController
    def create
      source = Webhooks::Source.slack
      return render_inert(source) unless source.accepting?
      return reject(413, source, "body over #{MAX_BODY_BYTES} bytes") if body_too_large?

      verification = SlackSignature.verify(
        secret: source.signing_secret,
        body: raw_body,
        timestamp: request.headers["X-Slack-Request-Timestamp"],
        signature: request.headers["X-Slack-Signature"]
      )
      return reject(:unauthorized, source, verification.reason) unless verification.valid?

      payload = parse_payload
      return reject(:bad_request, source, "body is not a JSON object") unless payload.is_a?(Hash)

      case payload["type"]
      when "url_verification"
        render json: { challenge: payload["challenge"].to_s }
      when "event_callback"
        accept_event(source, payload)
      else
        # app_rate_limited and anything Slack adds later. Acknowledged so Slack does not retry it.
        head :ok
      end
    end

    private

    def parse_payload
      JSON.parse(raw_body)
    rescue JSON::ParserError
      nil
    end

    # Record the delivery and enqueue its processing in one transaction. GoodJob's queue is this
    # database, so either both commit or neither does: a crash in between leaves no row, Slack's
    # retry finds none, and the event is processed then.
    def accept_event(source, payload)
      event_id = payload["event_id"].to_s
      event = payload["event"]
      return reject(:bad_request, source, "event_callback with no event_id or event") if event_id.blank? || !event.is_a?(Hash)

      first = ActiveRecord::Base.transaction do
        recorded = WebhookDelivery.record_first!(
          source: source.name,
          delivery_id: event_id,
          event_type: event["type"].to_s.presence,
          retry_num: request.headers["X-Slack-Retry-Num"].presence&.to_i
        )
        SlackEventJob.perform_later(event_id, SlackEventJob.event_arguments(event)) if recorded
        recorded
      end

      unless first
        Rails.logger.info("[Webhooks::SlackController] Slack redelivered event #{event_id} " \
                          "(retry #{request.headers['X-Slack-Retry-Num'].inspect}); already accepted, not processing it again")
      end

      render json: { ok: true, duplicate: !first }
    end
  end
end
