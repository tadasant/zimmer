# frozen_string_literal: true

module Apns
  # The APNs provider credential, read through SecretProviders.chain (the
  # Parameter Store, then Rails credentials, then the process environment) on
  # every call, so a key placed in the store takes effect without a restart.
  #
  #   APNS_AUTH_KEY_P8  the .p8 file's contents (a PEM EC private key). Secret.
  #   APNS_KEY_ID       the key's ten-character Key ID.
  #   APNS_TEAM_ID      the Apple Developer team ID.
  #   APNS_TOPIC        the app's bundle id; default com.tadasant.zimmer.
  #
  # The key is team-scoped and enabled for both Sandbox and Production, so one
  # credential serves a development build and a TestFlight build alike. Until all
  # three of the first values are present and the key parses, `configured?` is
  # false and ApnsService sends nothing — it is inert, not failing.
  class Config
    KEY_P8 = "APNS_AUTH_KEY_P8"
    KEY_ID = "APNS_KEY_ID"
    TEAM_ID = "APNS_TEAM_ID"
    TOPIC = "APNS_TOPIC"
    DEFAULT_TOPIC = "com.tadasant.zimmer"

    def self.current
      new
    end

    def configured?
      key_id.present? && team_id.present? && signing_key.present?
    end

    # Why nothing is being sent, for the log line and the health surface.
    def missing
      [
        (KEY_P8 if signing_key.nil?),
        (KEY_ID if key_id.blank?),
        (TEAM_ID if team_id.blank?)
      ].compact
    end

    def key_id = @key_id ||= read(KEY_ID)
    def team_id = @team_id ||= read(TEAM_ID)
    def topic = @topic ||= read(TOPIC) || DEFAULT_TOPIC

    # @return [OpenSSL::PKey::EC, nil]
    def signing_key
      return @signing_key if defined?(@signing_key)

      pem = read(KEY_P8)
      @signing_key = pem && OpenSSL::PKey::EC.new(pem)
    rescue OpenSSL::PKey::PKeyError
      Rails.logger.error("[apns] #{KEY_P8} is set but is not a PEM EC private key; push is off until it is")
      @signing_key = nil
    end

    private

    def read(key)
      SecretProviders.chain.get(key).presence
    rescue StandardError => e
      Rails.logger.warn("[apns] reading #{key} from the secret store failed (#{e.class}); using the process environment")
      ENV[key].presence
    end
  end
end
