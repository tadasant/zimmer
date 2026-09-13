# frozen_string_literal: true

module Webhooks
  # GitHub's webhook signing: `X-Hub-Signature-256` is `sha256=` followed by the hex HMAC-SHA256 of
  # the raw body, keyed with the webhook's secret.
  #
  # Verified against the RAW body, before anything parses it. A signature over bytes says nothing
  # about a re-serialization of them.
  #
  # GitHub signs no timestamp, so there is no freshness window to bound a replay the way Slack's
  # scheme does. What stops a captured delivery doing anything twice is its `X-GitHub-Delivery` id,
  # which WebhookDelivery records under a unique index, and the per-condition claim a fire takes
  # (TriggerEventClaim) — see Webhooks::GithubController.
  module GithubSignature
    PREFIX = "sha256="

    Result = Data.define(:reason) do
      def valid?
        reason.nil?
      end
    end

    module_function

    def verify(secret:, body:, signature:)
      return Result.new(reason: "no webhook secret configured") if secret.blank?
      return Result.new(reason: "missing X-Hub-Signature-256") if signature.blank?
      return Result.new(reason: "X-Hub-Signature-256 is not a sha256= signature") unless signature.to_s.start_with?(PREFIX)
      return Result.new(reason: "signature mismatch") unless Hmac.matches?(sign(secret: secret, body: body), signature)

      Result.new(reason: nil)
    end

    # The header value GitHub would send for +body+.
    def sign(secret:, body:)
      "#{PREFIX}#{Hmac.sha256_hex(secret, body)}"
    end
  end
end
