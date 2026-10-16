# frozen_string_literal: true

require "test_helper"
require "support/fake_parameter_store"

class SecretPresenceTest < ActiveSupport::TestCase
  VARIABLE = "LIVE_OPENAI_API_KEY"

  setup do
    @store = FakeParameterStore.new
  end

  test "a value in the store is present and in the store" do
    @store.seed_secret(VARIABLE, "sk-from-the-store")

    status = SecretPresence.for(VARIABLE, chain: chain)

    assert status.present?
    assert status.in_store?
    assert status.store_configured?
    assert_equal SecretProviders::ParameterStoreProvider::BADGE, status.provider_badge
    assert_equal "/zimmer/test/secrets/static/#{VARIABLE}", status.path
  end

  test "a value from ENV is present but not in the store" do
    status = SecretPresence.for(VARIABLE, chain: chain(env: { VARIABLE => "sk-from-env" }))

    assert status.present?
    assert_not status.in_store?
    assert status.store_configured?
    assert_equal SecretProviders::Env::BADGE, status.provider_badge
  end

  test "an absent value is not present" do
    status = SecretPresence.for(VARIABLE, chain: chain)

    assert_not status.present?
    assert_not status.in_store?
    assert_nil status.provider_badge
  end

  test "a store that cannot be consulted reads as not set rather than raising" do
    @store.fail_with!(503)

    status = SecretPresence.for(VARIABLE, chain: chain)

    assert_not status.present?
    assert status.store_configured?
  end

  test "a chain with no store link says so" do
    status = SecretPresence.for(VARIABLE,
      chain: SecretProviders::Chain.new([ SecretProviders::Env.new({ VARIABLE => "sk-from-env" }) ]))

    assert status.present?
    assert_not status.store_configured?
    assert_not status.in_store?
  end

  test "the status never carries the value" do
    @store.seed_secret(VARIABLE, "sk-must-not-appear")

    status = SecretPresence.for(VARIABLE, chain: chain)

    assert_no_match(/sk-must-not-appear/, status.to_h.values.join(" "))
  end

  private

  def chain(env: {})
    SecretProviders::Chain.new([ @store.provider, SecretProviders::Env.new(env) ])
  end
end
