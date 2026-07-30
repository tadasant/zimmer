# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "support/fake_parameter_store"

class SecretProvidersTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @fake = FakeParameterStore.new
    SecretProviders.reset!
  end

  teardown { SecretProviders.reset! }

  def credentials(values)
    SecretsLoader.stubs(:exists?).returns(false)
    SecretsLoader.stubs(:get).returns(nil)
    values.each do |name, value|
      SecretsLoader.stubs(:exists?).with(name).returns(true)
      SecretsLoader.stubs(:get).with(name).returns(value)
    end
  end

  def chain_with_store(env: {})
    SecretProviders::Chain.new([
      @fake.provider,
      SecretProviders::RailsCredentials.new,
      SecretProviders::Env.new(env)
    ])
  end

  # --- composition -----------------------------------------------------------

  test "without a resolver credential the chain is credentials then env" do
    chain = SecretProviders.build(env: {})

    assert_equal %w[rails_credentials env], chain.providers.map(&:name)
  end

  test "a partial resolver configuration does not silently half-enable the store" do
    chain = SecretProviders.build(env: { "ZIMMER_PARAMS_PROJECT_ID" => "zimmer-secrets-prod" })

    assert_equal %w[rails_credentials env], chain.providers.map(&:name)
    assert_match "ZIMMER_PARAMS_RESOLVER_SERVICE_ACCOUNT_KEY_JSON",
      SecretProviders.parameter_store_configuration(env: { "ZIMMER_PARAMS_PROJECT_ID" => "p" }).reason
  end

  test "malformed key JSON degrades to the existing chain and says why" do
    env = {
      "ZIMMER_PARAMS_PROJECT_ID" => "zimmer-secrets-prod",
      "ZIMMER_PARAMS_RESOLVER_SERVICE_ACCOUNT_KEY_JSON" => "not json"
    }

    assert_equal %w[rails_credentials env], SecretProviders.build(env: env).providers.map(&:name)
    assert_match "is not valid JSON, nor base64 of valid JSON",
      SecretProviders.parameter_store_configuration(env: env).reason
  end

  test "a well-formed key JSON puts the store first in the chain" do
    key = JSON.generate({ client_email: "resolver@zimmer-secrets-prod.iam.gserviceaccount.com",
                          private_key: "-----BEGIN PRIVATE KEY-----\\nx\\n-----END PRIVATE KEY-----" })
    env = {
      "ZIMMER_PARAMS_PROJECT_ID" => "zimmer-secrets-prod",
      "ZIMMER_PARAMS_RESOLVER_SERVICE_ACCOUNT_KEY_JSON" => key
    }

    chain = SecretProviders.build(env: env)

    assert_equal %w[parameter_store rails_credentials env], chain.providers.map(&:name)
    assert SecretProviders.parameter_store_configuration(env: env).configured?
  end

  # --- precedence ------------------------------------------------------------

  test "the store wins over an encrypted-credentials copy of the same name" do
    @fake.seed_secret("STRAD_API_KEY", "from-the-store")
    credentials("STRAD_API_KEY" => "from-the-credentials-file")

    assert_equal "from-the-store", chain_with_store.get("STRAD_API_KEY")
  end

  test "a name the store does not hold still resolves from the credentials file" do
    credentials("SLACK_BOT_TOKEN" => "xoxb-legacy")

    assert_equal "xoxb-legacy", chain_with_store.get("SLACK_BOT_TOKEN")
  end

  test "a name in neither still resolves from the process environment" do
    credentials({})

    assert_equal "from-env", chain_with_store(env: { "ONLY_IN_ENV" => "from-env" }).get("ONLY_IN_ENV")
  end

  test "an absent name is nil, not an error" do
    credentials({})

    assert_nil chain_with_store.get("NOWHERE")
  end

  # --- miss vs error ---------------------------------------------------------

  test "an unreachable store raises instead of falling through to a stale copy" do
    credentials("STRAD_API_KEY" => "stale-value-from-before-the-rotation")
    @fake.fail_with!(503)

    assert_raises(ParameterStore::StoreError) { chain_with_store.get("STRAD_API_KEY") }
  end

  test "provider_for names the holder without returning the value" do
    @fake.seed_secret("STRAD_API_KEY", "sk-live")
    credentials("SLACK_BOT_TOKEN" => "xoxb")
    chain = chain_with_store

    assert_equal "parameter_store", chain.provider_for("STRAD_API_KEY").name
    assert_equal "rails_credentials", chain.provider_for("SLACK_BOT_TOKEN").name
    assert_nil chain.provider_for("NOWHERE")
  end

  # --- caching ---------------------------------------------------------------

  test "a namespace is read once and served from the snapshot" do
    @fake.seed_secret("A", "1")
    @fake.seed_secret("B", "2")
    provider = @fake.provider

    assert_equal "1", provider.get("A")
    reads = @fake.requests.size
    assert_equal "2", provider.get("B")

    assert_equal reads, @fake.requests.size, "the second name must come from the snapshot"
  end

  test "a store that fails after a good read serves the last known values" do
    @fake.seed_secret("STRAD_API_KEY", "sk-live")
    provider = @fake.provider
    assert_equal "sk-live", provider.get("STRAD_API_KEY")

    # Let the snapshot go stale so the next read actually attempts a refresh.
    @fake.fail_with!(503)
    travel 2.minutes do
      assert_equal "sk-live", provider.get("STRAD_API_KEY"),
        "a warm snapshot rides out an outage rather than reporting the secret as missing"
    end
  end

  test "invalidate forces a real read, so a write is never masked by a stale snapshot" do
    @fake.seed_secret("STRAD_API_KEY", "old")
    provider = @fake.provider
    assert_equal "old", provider.get("STRAD_API_KEY")

    @fake.secrets[ParameterStore::Namespace.parameter_id(
      ParameterStore::Namespace.parameter_path("STRAD_API_KEY")
    )] << "rotated"
    provider.invalidate

    assert_equal "rotated", provider.get("STRAD_API_KEY")
  end

  test "a cold store failure raises rather than reporting every secret as absent" do
    @fake.fail_with!(503)

    assert_raises(ParameterStore::StoreError) { @fake.provider.get("STRAD_API_KEY") }
  end

  test "a name added after the snapshot was taken appears within the negative TTL" do
    # Regression: the miss path fires while the snapshot is FRESH, so a refresh
    # that short-circuits on staleness would hide a newly-added secret for a full
    # TTL (60s) instead of the negative TTL (10s).
    @fake.seed_secret("FIRST", "1")
    provider = @fake.provider
    assert_equal "1", provider.get("FIRST")
    assert_nil provider.get("SECOND")

    @fake.seed_secret("SECOND", "2")

    travel 11.seconds do
      assert_equal "2", provider.get("SECOND"),
        "a newly added name must not wait for the full snapshot TTL"
    end
  end

  test "a miss for a name that genuinely does not exist is rate limited" do
    @fake.seed_secret("FIRST", "1")
    provider = @fake.provider
    provider.get("FIRST")
    reads = @fake.requests.size

    5.times { assert_nil provider.get("NEVER_EXISTS") }

    assert_operator @fake.requests.size - reads, :<=, 4,
      "repeated lookups of an absent name must not become a store round trip each"
  end
end
