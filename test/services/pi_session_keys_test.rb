# frozen_string_literal: true

require "test_helper"

class PiSessionKeysTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @api = FakeOpenrouterKeysApi.start
    @client = @api.client
  end

  teardown { @api.stop }

  # --- configuration ---------------------------------------------------------

  test "mode is off unless explicitly on, and an unrecognised value is off" do
    assert_equal "off", PiSessionKeys.mode(env: {})
    assert_equal "off", PiSessionKeys.mode(env: { "PI_OPENROUTER_SESSION_KEYS" => "" })
    assert_equal "off", PiSessionKeys.mode(env: { "PI_OPENROUTER_SESSION_KEYS" => "yes" })
    assert_equal "on", PiSessionKeys.mode(env: { "PI_OPENROUTER_SESSION_KEYS" => " ON " })
    assert_equal "on_with_fallback", PiSessionKeys.mode(env: { "PI_OPENROUTER_SESSION_KEYS" => "on_with_fallback" })
  end

  test "limit and ttl default, parse and clamp" do
    assert_equal 20, PiSessionKeys.limit_usd(env: {})
    assert_equal 7.5, PiSessionKeys.limit_usd(env: { "PI_OPENROUTER_SESSION_KEY_LIMIT_USD" => "7.5" })
    assert_equal 20, PiSessionKeys.limit_usd(env: { "PI_OPENROUTER_SESSION_KEY_LIMIT_USD" => "-1" })
    assert_equal 20, PiSessionKeys.limit_usd(env: { "PI_OPENROUTER_SESSION_KEY_LIMIT_USD" => "lots" })

    assert_equal 24.hours, PiSessionKeys.ttl(env: {})
    assert_equal 6.hours, PiSessionKeys.ttl(env: { "PI_OPENROUTER_SESSION_KEY_TTL_HOURS" => "6" })
    assert_equal 1.hour, PiSessionKeys.ttl(env: { "PI_OPENROUTER_SESSION_KEY_TTL_HOURS" => "0.1" })
    assert_equal 168.hours, PiSessionKeys.ttl(env: { "PI_OPENROUTER_SESSION_KEY_TTL_HOURS" => "9999" })
  end

  # --- the management key comes from the store and nowhere else -------------

  test "the management key resolves from the Parameter Store" do
    store = FakeParameterStore.new
    store.seed_secret("OPENROUTER_MANAGEMENT_KEY", "mgmt-from-store")

    assert_equal "mgmt-from-store", PiSessionKeys.management_key(chain: store.chain)
  end

  test "a management key in ENV or encrypted credentials does not count" do
    chain = SecretProviders::Chain.new([ SecretProviders::Env.new({ "OPENROUTER_MANAGEMENT_KEY" => "mgmt-from-env" }) ])

    assert_nil PiSessionKeys.management_key(chain: chain)
  end

  test "an unreachable store reads as no management key" do
    store = FakeParameterStore.new
    store.seed_secret("OPENROUTER_MANAGEMENT_KEY", "mgmt-from-store")
    chain = store.chain
    store.fail_with!(503)

    assert_nil PiSessionKeys.management_key(chain: chain)
  end

  test "the name prefix is stable and says nothing about the secret" do
    assert_equal PiSessionKeys.name_prefix, PiSessionKeys.name_prefix
    assert_match(/\Azimmer-pi-[0-9a-f]{10}-\z/, PiSessionKeys.name_prefix)
  end

  # --- mint ------------------------------------------------------------------

  test "mint_for_spawn! creates a capped, expiring key, records its hash and never its plaintext" do
    session = sessions(:running)
    now = Time.zone.parse("2026-11-22T12:00:00Z")

    key = PiSessionKeys.mint_for_spawn!(session_id: session.id, client: @client, now: now)

    record = PiProviderKey.sole
    assert_equal @api.keys[record.key_hash]["key"], key
    assert_equal session.id, record.session_id
    assert_equal 20, record.limit_usd
    assert_equal now + 24.hours, record.expires_at
    assert record.name.start_with?(PiSessionKeys.name_prefix)
    refute(PiProviderKey.columns.any? { |column| record[column.name].to_s.include?(key) })
    assert_equal 20.0, @api.keys[record.key_hash]["limit"]
  end

  test "mint_for_spawn! hands the session's earlier keys to a revoke job cut off before the new key" do
    session = sessions(:running)
    now = Time.current

    assert_enqueued_with(job: PiProviderKeyRevokeJob, args: [ session.id, now.iso8601(6), "superseded" ]) do
      PiSessionKeys.mint_for_spawn!(session_id: session.id, client: @client, now: now)
    end
  end

  test "a refused mint raises MintError and records nothing" do
    @api.fail_next("POST", 402, message: "Insufficient credits")

    error = assert_raises(PiSessionKeys::MintError) do
      PiSessionKeys.mint_for_spawn!(session_id: sessions(:running).id, client: @client)
    end
    assert_includes error.message, "402"
    assert_equal 0, PiProviderKey.count
  end

  test "a key whose row cannot be written is deleted at OpenRouter rather than left behind" do
    PiProviderKey.stub(:create!, ->(**) { raise ActiveRecord::ConnectionNotEstablished }) do
      assert_raises(PiSessionKeys::MintError) do
        PiSessionKeys.mint_for_spawn!(session_id: sessions(:running).id, client: @client)
      end
    end

    assert_empty @api.live_hashes
  end

  # --- revoke ----------------------------------------------------------------

  test "revoke! deletes the key and records what it spent" do
    PiSessionKeys.mint_for_spawn!(session_id: sessions(:running).id, client: @client)
    record = PiProviderKey.sole
    @api.set_usage(record.key_hash, 1.234567)

    assert PiSessionKeys.revoke!(record, reason: "session_at_rest", client: @client)

    record.reload
    assert_not_nil record.revoked_at
    assert_equal "session_at_rest", record.revoke_reason
    assert_equal BigDecimal("1.234567"), record.usage_usd
    assert_empty @api.live_hashes
  end

  test "a key OpenRouter no longer has counts as revoked" do
    record = PiProviderKey.create!(key_hash: "gone", name: "n", limit_usd: 1, expires_at: 1.hour.from_now)

    assert PiSessionKeys.revoke!(record, reason: "expired", client: @client)
    assert_not_nil record.reload.revoked_at
  end

  test "a failed delete leaves the key active with its error, for the sweep to retry" do
    PiSessionKeys.mint_for_spawn!(session_id: sessions(:running).id, client: @client)
    record = PiProviderKey.sole
    @api.fail_next("DELETE", 500, message: "Internal Server Error")

    refute PiSessionKeys.revoke!(record, reason: "session_at_rest", client: @client)

    record.reload
    assert_nil record.revoked_at
    assert_includes record.last_error, "500"
  end

  test "revoke_for_session! leaves keys minted after the cutoff alone" do
    session = sessions(:running)
    old = PiProviderKey.create!(session_id: session.id, key_hash: @api.seed_key(name: "a"), name: "a",
                                limit_usd: 1, expires_at: 1.hour.from_now, created_at: 2.minutes.ago)
    fresh = PiProviderKey.create!(session_id: session.id, key_hash: @api.seed_key(name: "b"), name: "b",
                                  limit_usd: 1, expires_at: 1.hour.from_now)

    assert_equal 1, PiSessionKeys.revoke_for_session!(session.id, cutoff: 1.minute.ago, reason: "superseded", client: @client)
    assert_not_nil old.reload.revoked_at
    assert_nil fresh.reload.revoked_at
    assert_equal [ fresh.key_hash ], @api.live_hashes
  end

  test "session_live? is running, or blocked on an elicitation with its process waiting" do
    assert PiSessionKeys.session_live?(sessions(:running))
    refute PiSessionKeys.session_live?(sessions(:needs_input))
    refute PiSessionKeys.session_live?(nil)

    blocked = sessions(:needs_input)
    blocked.metadata = (blocked.metadata || {}).merge("blocked_on_elicitation" => true)
    assert PiSessionKeys.session_live?(blocked)
  end
end
