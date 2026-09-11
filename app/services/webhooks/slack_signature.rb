# frozen_string_literal: true

module Webhooks
  # Slack's v0 request signing: `X-Slack-Signature` is `v0=` followed by the hex HMAC-SHA256 of
  # `v0:<X-Slack-Request-Timestamp>:<raw body>`, keyed with the app's signing secret.
  #
  # Verified against the RAW body, before anything parses it. A signature over bytes says nothing
  # about a re-serialization of them.
  #
  # The timestamp is part of what is signed, so bounding its age is what makes a captured request
  # useless to replay later. Slack's own guidance is five minutes.
  module SlackSignature
    VERSION = "v0"
    FRESHNESS_WINDOW = 5.minutes

    Result = Data.define(:reason) do
      def valid?
        reason.nil?
      end
    end

    module_function

    def verify(secret:, body:, timestamp:, signature:, now: Time.current)
      return Result.new(reason: "no signing secret configured") if secret.blank?
      return Result.new(reason: "missing X-Slack-Request-Timestamp or X-Slack-Signature") if timestamp.blank? || signature.blank?
      return Result.new(reason: "malformed X-Slack-Request-Timestamp") unless timestamp.to_s.match?(/\A\d{1,12}\z/)

      if (now.to_i - timestamp.to_i).abs > FRESHNESS_WINDOW.to_i
        return Result.new(reason: "timestamp outside the #{FRESHNESS_WINDOW.inspect} freshness window")
      end

      return Result.new(reason: "signature mismatch") unless Hmac.matches?(sign(secret: secret, body: body, timestamp: timestamp), signature)

      Result.new(reason: nil)
    end

    # The header value Slack would send for +body+ at +timestamp+.
    def sign(secret:, body:, timestamp:)
      "#{VERSION}=#{Hmac.sha256_hex(secret, "#{VERSION}:#{timestamp}:#{body}")}"
    end
  end
end
