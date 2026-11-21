# frozen_string_literal: true

require "openssl"
require "base64"

# Turns Zimmer's hosted OAuth client identity (OauthClientIdentity) on for the
# duration of a block, with a local signing key, and back off afterwards.
module OauthClientIdentityHelpers
  IDENTITY_ENV_KEYS = [
    OauthClientIdentity::BASE_URL_ENV,
    OauthClientIdentity::KeySet::LOCAL_KEYS_ENV,
    OauthClientIdentity::KeySet::KMS_KEY_VERSIONS_ENV
  ].freeze

  def generate_ec_key = OpenSSL::PKey::EC.generate("prime256v1")

  def generate_rsa_key = OpenSSL::PKey::RSA.new(2048)

  def local_key_value(key) = Base64.strict_encode64(key.private_to_pem)

  # @param keys [Array<OpenSSL::PKey>] signing keys, active first
  def with_oauth_client_identity(base_url: "https://zimmer.example.com", keys: [ generate_ec_key ])
    saved = IDENTITY_ENV_KEYS.to_h { |k| [ k, ENV[k] ] }
    ENV[OauthClientIdentity::BASE_URL_ENV] = base_url
    ENV[OauthClientIdentity::KeySet::LOCAL_KEYS_ENV] = keys.map { |k| local_key_value(k) }.join(",")
    ENV.delete(OauthClientIdentity::KeySet::KMS_KEY_VERSIONS_ENV)
    OauthClientIdentity.reset!
    yield keys
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    OauthClientIdentity.reset!
  end
end
