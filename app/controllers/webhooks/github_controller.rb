# frozen_string_literal: true

module Webhooks
  # A GitHub repository or organization webhook: `POST /webhooks/github`.
  #
  # Every delivery that verifies is recorded in WebhookDelivery under its `X-GitHub-Delivery` id,
  # whatever its event, so the table answers "is GitHub delivering at all". A redelivery — GitHub's
  # "Redeliver" button, or a replay of a captured request — carries the same id and is acknowledged
  # without being processed again.
  #
  # Only the events in FIRING_EVENTS fire anything: they are handed to GithubEventJob, which fires
  # the conditions the poller would. Everything else — `ping` when the hook is saved, a closed
  # issue, a review requested — is acknowledged so GitHub records a success, and fires nothing.
  #
  # The body must be `application/json`. A hook configured for `application/x-www-form-urlencoded`
  # sends a body that is not JSON and gets a 400.
  #
  # See Webhooks::BaseController for the order every check runs in.
  class GithubController < BaseController
    # "<event>.<action>" => the payload key carrying the item. These are the deliveries that can
    # put an item into a search GithubTriggerPollerJob runs: a new issue for a `github_issue`
    # condition's cursor, and for a `github_label` condition's seen-set a label added to an open
    # item or an item becoming open while carrying one.
    FIRING_EVENTS = {
      "issues.opened" => "issue",
      "issues.reopened" => "issue",
      "issues.labeled" => "issue",
      "pull_request.opened" => "pull_request",
      "pull_request.reopened" => "pull_request",
      "pull_request.labeled" => "pull_request"
    }.freeze

    def create
      source = Webhooks::Source.github
      return render_inert(source) unless source.accepting?
      return reject(413, source, "body over #{MAX_BODY_BYTES} bytes") if body_too_large?

      verification = GithubSignature.verify(
        secret: source.signing_secret,
        body: raw_body,
        signature: request.headers["X-Hub-Signature-256"]
      )
      return reject(:unauthorized, source, verification.reason) unless verification.valid?

      delivery_id = request.headers["X-GitHub-Delivery"].to_s
      event = request.headers["X-GitHub-Event"].to_s
      return reject(:bad_request, source, "no X-GitHub-Delivery or X-GitHub-Event header") if delivery_id.blank? || event.blank?

      payload = parse_payload
      return reject(:bad_request, source, "body is not a JSON object") unless payload.is_a?(Hash)

      accept_delivery(source, delivery_id, event, payload)
    end

    private

    # Record the delivery and enqueue its processing in one transaction, as the Slack endpoint does:
    # GoodJob's queue is this database, so either both commit or neither does.
    def accept_delivery(source, delivery_id, event, payload)
      action = payload["action"].to_s.presence
      event_type = [ event, action ].compact.join(".")
      item_key = FIRING_EVENTS[event_type]
      object = item_key && payload[item_key]
      label = payload["label"].is_a?(Hash) ? payload["label"]["name"].to_s.presence : nil

      # A `labeled` delivery whose `label` is missing names nothing that could have been added, so
      # there is no event in it to match a condition's labels against.
      fires = object.is_a?(Hash) && (!event_type.end_with?(".labeled") || label.present?)

      first = ActiveRecord::Base.transaction do
        recorded = WebhookDelivery.record_first!(
          source: source.name,
          delivery_id: delivery_id,
          event_type: event_type
        )
        if recorded && fires
          GithubEventJob.perform_later(
            delivery_id, event_type,
            GithubEventJob.item_arguments(object, repository: payload["repository"], pull_request: item_key == "pull_request"),
            label
          )
        end
        recorded
      end

      unless first
        Rails.logger.info("[Webhooks::GithubController] GitHub redelivered #{delivery_id} (#{event}); " \
                          "already accepted, not processing it again")
      end

      render json: { ok: true, duplicate: !first }
    end
  end
end
