# frozen_string_literal: true

module Webhooks
  # Standard Webhooks request signing, the scheme MCP Events webhook delivery profiles (SEP-3415 @
  # b08e4f9, "Webhook security"):
  #
  #   webhook-id         the message id, reused across retries of one message
  #   webhook-timestamp  Unix seconds of THIS attempt; a retry regenerates it
  #   webhook-signature  space-delimited `v1,<base64 HMAC-SHA256>` entries — several during a
  #                      secret rotation, any one of which may verify
  #
  # The HMAC is over `<webhook-id>.<webhook-timestamp>.<raw body>`, keyed with the base64-decoded
  # bytes after the secret's `whsec_` prefix. Verified against the RAW body, before anything parses
  # it, and the timestamp is bounded to FRESHNESS_WINDOW so a captured request cannot be replayed
  # later. Entries of any other version (`v1a,` — the SEP's optional ed25519 server identity) are
  # skipped, as an endpoint that does not enforce server identity is told to.
  module StandardWebhooksSignature
    SECRET_PREFIX = "whsec_"
    VERSION = "v1"
    FRESHNESS_WINDOW = 5.minutes

    # The SEP's `webhook-id` charset: ASCII letters, digits, `_` and `-`.
    MESSAGE_ID_FORMAT = /\A[A-Za-z0-9_-]{1,255}\z/

    # The SEP bounds a secret to 24..64 random bytes; Zimmer mints 32.
    SECRET_BYTES = 32

    Result = Data.define(:reason) do
      def valid?
        reason.nil?
      end
    end

    module_function

    # A fresh `whsec_` secret from a CSPRNG.
    def generate_secret
      "#{SECRET_PREFIX}#{Base64.strict_encode64(SecureRandom.random_bytes(SECRET_BYTES))}"
    end

    def verify(secret:, body:, message_id:, timestamp:, signature:, now: Time.current)
      key = key_bytes(secret)
      return Result.new(reason: "no usable signing secret") if key.nil?
      return Result.new(reason: "missing webhook-id, webhook-timestamp or webhook-signature") if message_id.blank? || timestamp.blank? || signature.blank?
      return Result.new(reason: "malformed webhook-id") unless message_id.to_s.match?(MESSAGE_ID_FORMAT)
      return Result.new(reason: "malformed webhook-timestamp") unless timestamp.to_s.match?(/\A\d{1,12}\z/)

      if (now.to_i - timestamp.to_i).abs > FRESHNESS_WINDOW.to_i
        return Result.new(reason: "timestamp outside the #{FRESHNESS_WINDOW.inspect} freshness window")
      end

      expected = digest(key, message_id, timestamp, body)
      given = signature.to_s.split(" ").filter_map do |entry|
        version, value = entry.split(",", 2)
        value if version == VERSION
      end
      # Every entry is compared, not just until the first match, so how many entries a forged
      # header carried is all its timing can say.
      matched = given.map { |value| Hmac.matches?(expected, value) }.any?
      return Result.new(reason: "signature mismatch") unless matched

      Result.new(reason: nil)
    end

    # The `webhook-signature` header a sender would put on +body+.
    def sign(secret:, body:, message_id:, timestamp:)
      "#{VERSION},#{digest(key_bytes(secret), message_id, timestamp, body)}"
    end

    # The secret's raw key bytes, or nil for a value that is not `whsec_<base64>`.
    def key_bytes(secret)
      value = secret.to_s
      return nil unless value.start_with?(SECRET_PREFIX)

      decoded = Base64.strict_decode64(value.delete_prefix(SECRET_PREFIX))
      decoded.bytesize.between?(24, 64) ? decoded : nil
    rescue ArgumentError
      nil
    end

    def digest(key, message_id, timestamp, body)
      Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", key, "#{message_id}.#{timestamp}.#{body}"))
    end
  end
end
