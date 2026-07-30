# frozen_string_literal: true

require "test_helper"
require "kamal"
require "openssl"

module ParameterStore
  # The resolver credential reaches production through Kamal, and that path mangles
  # things -- quietly, which is what makes it worth a test.
  #
  # Kamal escapes each env value with Ruby's String#dump (Kamal::EnvFile), writing one
  # line per variable into a Docker env-file. Docker's --env-file parser unescapes
  # NOTHING: it splits on the first `=`, takes the rest of the line literally, and hands
  # that to the process. So a real newline makes the round trip as the two characters
  # `\n`, and the pretty-printed JSON `gcloud iam service-accounts keys create` writes
  # arrives as something JSON.parse rejects.
  #
  # That equivalence -- "what Docker delivers == what Kamal::EnvFile escaped" -- was
  # verified against a real `docker run --env-file` (Docker 29.6.1) before this test was
  # written: the pretty, minified and base64 forms of a 2048-bit key arrived at 2407,
  # 2348 and 3096 bytes, matching the escaped lengths byte for byte, all on one line.
  # `through_kamal_env_file` below models exactly that, so CI can keep asserting it
  # without a Docker daemon.
  class ServiceAccountTest < ActiveSupport::TestCase
    EMAIL = "zimmer-secrets-resolver@zimmer-secrets-prod.iam.gserviceaccount.com"

    setup do
      @pem = OpenSSL::PKey::RSA.new(2048).to_pem
      @key = {
        "type" => "service_account",
        "project_id" => "zimmer-secrets-prod",
        "private_key" => @pem,
        "client_email" => EMAIL
      }
    end

    # What `gcloud iam service-accounts keys create` writes to disk, and therefore what
    # a human pastes into a GitHub Actions secret unless told otherwise.
    def pretty = JSON.pretty_generate(@key) + "\n"
    def minified = JSON.generate(@key)
    def base64 = Base64.strict_encode64(minified)

    # The bytes the container's process actually receives. See the class comment.
    def through_kamal_env_file(value)
      Kamal::EnvFile.new({ "ZIMMER_PARAMS_RESOLVER_SERVICE_ACCOUNT_KEY_JSON" => value })
        .to_s.chomp.delete_prefix("ZIMMER_PARAMS_RESOLVER_SERVICE_ACCOUNT_KEY_JSON=")
    end

    def assert_usable_key(raw, message = nil)
      account, reason = ServiceAccount.parse(raw)

      assert account, "#{message} -- rejected as #{reason.inspect}"
      assert_equal EMAIL, account.client_email
      # The PEM is the half that a botched round trip corrupts without changing shape:
      # JSON can parse fine and still hand OpenSSL a key with `\n` where its line breaks
      # belong. Assert the signing key, not just the parse.
      assert_equal @pem, OpenSSL::PKey::RSA.new(account.send(:pem)).to_pem, message
    end

    # --- the env-file round trip ----------------------------------------------

    test "base64 survives the Kamal env-file trip and yields the original key" do
      delivered = through_kamal_env_file(base64)

      assert_equal base64, delivered, "base64 has no byte that Kamal's escaping touches."
      assert_usable_key delivered, "Base64 is the documented delivery form; it must survive."
    end

    test "pretty-printed key JSON does NOT survive the trip -- the reason base64 exists" do
      delivered = through_kamal_env_file(pretty)

      assert_equal 1, delivered.lines.size, "Kamal collapses it to one line; it is not truncated."
      assert_includes delivered, '\n', "The structural newlines arrive as two literal characters."

      account, reason = ServiceAccount.parse(delivered)

      assert_nil account,
        "If this ever starts passing, Docker's env-file parser changed and the base64 " \
        "requirement in .kamal/secrets.production can be revisited."
      assert_match "is not valid JSON", reason
    end

    test "minified key JSON survives, so a jq -c paste is not a silent corruption" do
      assert_usable_key through_kamal_env_file(minified),
        "Minified JSON has no structural newlines, so only its \\n escapes get doubled -- " \
        "and JSON.parse collapses those back."
    end

    # --- shapes accepted directly ---------------------------------------------

    test "raw JSON is still accepted, env-file or not" do
      assert_usable_key pretty, "A console setting ENV[...] directly has no env-file in the path."
      assert_usable_key minified
      assert_usable_key base64
    end

    test "wrapped base64 is accepted, because `base64` without -w0 wraps at 76 columns" do
      assert_usable_key Base64.encode64(minified)
    end

    # --- failures, reported by shape ------------------------------------------

    test "neither JSON nor base64 is one reason, not a misleading base64 error" do
      account, reason = ServiceAccount.parse("not json")

      assert_nil account
      assert_equal "is not valid JSON, nor base64 of valid JSON", reason
    end

    test "base64 of something that is not a key JSON is a shape failure" do
      account, reason = ServiceAccount.parse(Base64.strict_encode64("hello there"))

      assert_nil account
      assert_match "is not valid JSON", reason
    end

    test "JSON that is not an object is a shape failure, not a crash" do
      [ "123", '"a string"', "[]" ].each do |raw|
        account, reason = ServiceAccount.parse(raw)

        assert_nil account, "#{raw} is not a key JSON"
        assert_match "is not valid JSON", reason
      end
    end

    test "a JSON object missing the two fields that matter says which" do
      account, reason = ServiceAccount.parse(JSON.generate({ "type" => "service_account" }))

      assert_nil account
      assert_equal "is missing client_email / private_key", reason
    end

    # An env var is bytes tagged UTF-8, valid or not, and String#blank? raises
    # ArgumentError on the invalid ones. Nothing about the shape of a truncated paste
    # announces this, and the raise would happen while the resolution chain is being
    # built -- so a mangled credential would take the process down rather than leaving
    # the store switched off. Found by fuzzing parse with 2000 hostile inputs.
    test "bytes that are not valid UTF-8 are a reason, not an ArgumentError" do
      mangled = "\xB8\xB7\x1F\xBDa[W$@".dup.force_encoding("UTF-8")
      assert_not mangled.valid_encoding?, "Sanity: this fixture must be invalid UTF-8."

      account, reason = ServiceAccount.parse(mangled)

      assert_nil account
      assert_equal "is not valid UTF-8", reason
    end

    test "a chain built on a mangled credential degrades instead of raising" do
      env = {
        Resolver::ENV_KEYS[:project_id] => "zimmer-secrets-prod",
        Resolver::ENV_KEYS[:key_json] => "\xC3\x28".dup.force_encoding("UTF-8")
      }

      assert_equal %w[rails_credentials env], SecretProviders.build(env: env).providers.map(&:name)
      assert_match "is not valid UTF-8", SecretProviders.parameter_store_configuration(env: env).reason
    end

    test "no key at all is not an error string about parsing" do
      assert_equal "no key JSON provided", ServiceAccount.parse(nil).last
      assert_equal "no key JSON provided", ServiceAccount.parse("").last
    end

    # A reason string ends up in logs and on the Connectors page. A malformed key is
    # still a key.
    test "no reason string quotes the input" do
      secret = Base64.strict_encode64(JSON.generate({ "private_key" => "s3cret-material" }))

      [ "not json", secret, JSON.generate({ "client_email" => "a@b.com" }) ].each do |raw|
        reason = ServiceAccount.parse(raw).last

        assert_not_includes reason, "s3cret-material"
        assert_not_includes reason, raw
      end
    end
  end
end
