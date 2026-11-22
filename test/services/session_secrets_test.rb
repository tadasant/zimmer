# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# SessionSecrets is the bundle `air prepare` and a clone's `.env` are built from.
# Values here are obvious fakes, and assertions name keys wherever a failure
# message could otherwise print a value.
class SessionSecretsTest < ActiveSupport::TestCase
  setup do
    @store = FakeParameterStore.new
    SecretsLoader.stubs(:all).returns(
      "CREDENTIALS_ONLY" => "from-credentials",
      "IN_BOTH" => "stale-credentials-copy"
    )
  end

  def chain_with_store(env: {})
    SecretProviders::Chain.new([
      @store.provider, SecretProviders::RailsCredentials.new, SecretProviders::Env.new(env)
    ])
  end

  test "carries a secret kept only in the store" do
    @store.seed_secret("STORE_ONLY", "from-the-store")

    secrets = SessionSecrets.all(chain: chain_with_store)

    assert_equal "from-the-store", secrets["STORE_ONLY"]
    assert_equal "from-credentials", secrets["CREDENTIALS_ONLY"]
  end

  test "the store wins over encrypted credentials, as in the chain" do
    @store.seed_secret("IN_BOTH", "fresh-store-copy")

    assert_equal "fresh-store-copy", SessionSecrets.all(chain: chain_with_store)["IN_BOTH"]
  end

  test "never draws on process ENV" do
    secrets = SessionSecrets.all(chain: chain_with_store(env: { "RAILS_MASTER_KEY" => "do-not-export" }))

    assert_not_includes secrets.keys, "RAILS_MASTER_KEY"
  end

  test "with no store configured it is exactly the encrypted credentials" do
    chain = SecretProviders::Chain.new([ SecretProviders::RailsCredentials.new, SecretProviders::Env.new({}) ])

    assert_equal %w[CREDENTIALS_ONLY IN_BOTH], SessionSecrets.all(chain: chain).keys.sort
  end

  test "a store that cannot be read falls back to encrypted credentials" do
    @store.seed_secret("STORE_ONLY", "from-the-store")
    @store.fail_with!(503)

    secrets = SessionSecrets.all(chain: chain_with_store)

    assert_equal %w[CREDENTIALS_ONLY IN_BOTH], secrets.keys.sort
  end

  test "a network failure reaching the store falls back the same way" do
    store = SecretProviders::ParameterStoreProvider.allocate
    store.stubs(:names).raises(SocketError, "getaddrinfo failed")
    chain = SecretProviders::Chain.new([ store, SecretProviders::RailsCredentials.new ])

    assert_equal %w[CREDENTIALS_ONLY IN_BOTH], SessionSecrets.all(chain: chain).keys.sort
  end
end
