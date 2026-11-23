# frozen_string_literal: true

require "test_helper"

# The encryption keys are derived from secret_key_base, and deriving them must not
# change anything else that is. Every cookie, signed URL and stored secret depends on
# Rails.application.key_generator staying what Rails' own defaults make it.
class ActiveRecordEncryptionTest < ActiveSupport::TestCase
  # Independent of Rails' configuration: what load_defaults 8.0 gives.
  def reference(salt, length, digest: OpenSSL::Digest::SHA256)
    OpenSSL::PKCS5.pbkdf2_hmac(Rails.application.secret_key_base, salt, 1000, length, digest.new)
  end

  test "the application's key generator derives with SHA256" do
    assert_equal reference("probe", 32), Rails.application.key_generator.generate_key("probe", 32)
    assert_not_equal reference("probe", 32, digest: OpenSSL::Digest::SHA1), Rails.application.key_generator.generate_key("probe", 32)
  end

  test "the encryption keys are the documented derivation, so they can be pinned later" do
    skip "explicit keys are configured" if Rails.application.credentials.dig(:active_record_encryption, :primary_key).present?

    %w[primary_key deterministic_key key_derivation_salt].each do |purpose|
      assert_equal reference("zimmer/active_record_encryption/#{purpose}", 32).unpack1("H*"),
        Rails.application.config.active_record.encryption.public_send(purpose)
    end
  end

  # The bug this guards against is asking the memoized generator for a key before
  # Rails has finished configuring it.
  test "no initializer asks the application's key generator for a key at boot" do
    offenders = Dir[Rails.root.join("config/initializers/**/*.rb"), Rails.root.join("config/*.rb")].select do |path|
      File.readlines(path).any? { |line| !line.match?(/\A\s*#/) && line.match?(/\bkey_generator\b|\bmessage_verifier\(|\bRails\.application\.message_verifiers\b/) }
    end

    assert_empty offenders.map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
  end
end
