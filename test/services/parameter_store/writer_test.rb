# frozen_string_literal: true

require "test_helper"

module ParameterStore
  class WriterTest < ActiveSupport::TestCase
    # A syntactically valid, throwaway RSA key. Never used against Google here —
    # ServiceAccount.parse only has to accept it.
    KEY = OpenSSL::PKey::RSA.generate(1024).to_pem

    def key_json(email)
      JSON.generate({ client_email: email, private_key: KEY })
    end

    def resolver_env
      {
        "ZIMMER_PARAMS_PROJECT_ID" => "zimmer-secrets-test",
        "ZIMMER_PARAMS_RESOLVER_SERVICE_ACCOUNT_KEY_JSON" => key_json("resolver@example.iam.gserviceaccount.com")
      }
    end

    test "without a Parameter Store there is nothing to write into" do
      configuration = Writer.from_env({})

      assert_not configuration.configured?
      assert_match(/resolver is not configured/, configuration.reason)
    end

    test "a dedicated writer key produces a writer identity" do
      configuration = Writer.from_env(resolver_env.merge(
        Writer::ENV_KEY_JSON => key_json("writer@example.iam.gserviceaccount.com")
      ))

      assert configuration.configured?
      assert configuration.dedicated_writer?
      assert_equal :writer, configuration.identity
    end

    test "the writer writes into the project the resolver reads from" do
      configuration = Writer.from_env(resolver_env.merge(
        Writer::ENV_KEY_JSON => key_json("writer@example.iam.gserviceaccount.com")
      ))

      # The one thing that must never drift: a value written to a project Zimmer
      # does not resolve from is accepted and never read — the documented trap.
      assert_equal "zimmer-secrets-test", configuration.client.project_id
      assert_equal "global", configuration.client.location
    end

    test "every API seam travels to the write client, the probe endpoint included" do
      # The permissions probe goes to Cloud Resource Manager. Dropping that one
      # seam sends the probe to the real API, which 401s — and the Pi tab then
      # reports "permissions could not be confirmed" in every deployment.
      configuration = Writer.from_env(resolver_env.merge(
        "ZIMMER_PARAMS_PM_API_BASE" => "https://pm.test",
        "ZIMMER_PARAMS_SM_API_BASE" => "https://sm.test",
        "ZIMMER_PARAMS_CRM_API_BASE" => "https://crm.test"
      ))

      seen = []
      transport = Object.new
      transport.define_singleton_method(:request) do |_method, url, _headers, _body|
        seen << url
        [ 200, JSON.generate({ permissions: [] }) ]
      end
      configuration.client.instance_variable_set(:@transport, transport)
      configuration.client.instance_variable_set(:@account, Class.new {
        def access_token(**) = "fake"
      }.new)

      configuration.client.held_permissions([ "x" ])

      assert seen.sole.start_with?("https://crm.test/"), "the probe went to #{seen.sole}"
    end

    test "with no writer key it falls back to the resolver's account and says so" do
      configuration = Writer.from_env(resolver_env)

      assert configuration.configured?
      assert_not configuration.dedicated_writer?
      assert_equal :resolver, configuration.identity
    end

    test "a mangled writer key switches the path off rather than raising" do
      configuration = Writer.from_env(resolver_env.merge(Writer::ENV_KEY_JSON => "not json at all"))

      assert_not configuration.configured?
      assert_match(/#{Writer::ENV_KEY_JSON}/, configuration.reason)
    end

    test "a writer key that is not valid UTF-8 is ignored rather than crashing the boot path" do
      # An env var arrives as bytes TAGGED UTF-8, and nothing guarantees they
      # are. String#blank? RAISES on those bytes, and this runs while the
      # resolution chain is being built — so the guard is what keeps a truncated
      # paste from taking the process down instead of switching the path off.
      mangled = "\xC3".dup.force_encoding(Encoding::UTF_8)
      assert_not mangled.valid_encoding?, "precondition: the string is tagged UTF-8 and is not"

      configuration = Writer.from_env(resolver_env.merge(Writer::ENV_KEY_JSON => mangled))

      # Falls back to the resolver rather than exploding in blank?.
      assert configuration.configured?
      assert_equal :resolver, configuration.identity
    end
  end
end
