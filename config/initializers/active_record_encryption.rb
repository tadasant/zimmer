# frozen_string_literal: true

# Keys for Active Record encryption (`encrypts`), used for secrets stored in the
# database (McpOauthCredential's token twins).
#
# If config/credentials/<env>.yml.enc carries an `active_record_encryption`
# block (`bin/rails db:encryption:init`), Rails uses it and this does nothing.
# Otherwise the three keys are derived from secret_key_base, so a deployment
# needs no new secret to turn encryption on: production already holds
# SECRET_KEY_BASE, and rotating it is already a planned event (it signs every
# session cookie).
#
# The derivation is the price of that convenience: rotating secret_key_base
# makes these ciphertexts unreadable. While the plaintext columns are still
# written (the expand phase, see McpOauthCredential::SECRET_COLUMNS) that loses
# nothing. Before the plaintext columns stop being written, pin explicit keys —
# set them in the credentials block above to the values derived here, so the
# ciphertext stays readable — if secret_key_base may ever rotate.
encryption = Rails.application.config.active_record.encryption
explicit = begin
  Rails.application.credentials.dig(:active_record_encryption, :primary_key)
rescue ActiveSupport::MessageEncryptor::InvalidMessage
  nil
end

if explicit.blank? && encryption.primary_key.blank?
  # A PRIVATE generator, never Rails.application.key_generator. Rails memoizes that
  # one, and its digest only becomes SHA256 after the initializers have run, so
  # merely asking for it here would freeze the whole app's generator at SHA1: every
  # cookie, signed URL and secret derived from secret_key_base would change.
  generator = ActiveSupport::KeyGenerator.new(
    Rails.application.secret_key_base, iterations: 1000, hash_digest_class: OpenSSL::Digest::SHA256
  )
  derive = ->(purpose) { generator.generate_key("zimmer/active_record_encryption/#{purpose}", 32).unpack1("H*") }
  encryption.primary_key = derive.call("primary_key")
  encryption.deterministic_key = derive.call("deterministic_key")
  encryption.key_derivation_salt = derive.call("key_derivation_salt")
end
