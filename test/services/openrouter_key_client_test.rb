# frozen_string_literal: true

require "test_helper"

class OpenrouterKeyClientTest < ActiveSupport::TestCase
  setup do
    @api = FakeOpenrouterKeysApi.start
    @client = @api.client(management_key: "mgmt-key-for-tests")
  end

  teardown { @api.stop }

  test "create posts name, a non-resetting limit and a second-precision UTC expiry with the management key" do
    expires_at = Time.utc(2026, 11, 23, 12, 0, 0)
    minted = @client.create(name: "zimmer-pi-test-s1", limit_usd: 20, expires_at: expires_at)

    method, target, body, authorization = @api.calls.last
    assert_equal [ "POST", "/api/v1/keys" ], [ method, target ]
    assert_equal "Bearer mgmt-key-for-tests", authorization
    assert_equal({ "name" => "zimmer-pi-test-s1", "limit" => 20.0, "limit_reset" => nil,
                   "expires_at" => "2026-11-23T12:00:00Z" }, JSON.parse(body))
    assert_match(/\Ask-or-v1-/, minted.key)
    assert_equal @api.keys.keys.last, minted.hash
  end

  test "a minted key never prints its plaintext" do
    minted = @client.create(name: "n", limit_usd: 1, expires_at: 1.hour.from_now)

    refute_includes minted.inspect, minted.key
    refute_includes minted.to_s, minted.key
    refute_includes @client.inspect, "mgmt-key-for-tests"
  end

  test "get, delete and list speak the hash-addressed routes" do
    minted = @client.create(name: "n", limit_usd: 1, expires_at: 1.hour.from_now)
    @api.set_usage(minted.hash, 0.42)

    assert_equal 0.42, @client.get(minted.hash)["usage"]
    assert_equal [ minted.hash ], @client.list.map { |key| key["hash"] }
    assert @client.delete(minted.hash)
    assert_empty @api.live_hashes
  end

  test "a refusal raises with the status and OpenRouter's message, not the body" do
    @api.fail_next("POST", 403, message: "Only management keys can perform this operation")

    error = assert_raises(OpenrouterKeyClient::Error) do
      @client.create(name: "n", limit_usd: 1, expires_at: 1.hour.from_now)
    end
    assert_equal 403, error.status
    assert_includes error.message, "Only management keys"
  end

  test "a missing key is a not_found error" do
    error = assert_raises(OpenrouterKeyClient::Error) { @client.delete("nope") }
    assert_predicate error, :not_found?
  end

  test "an unreachable OpenRouter is an Error, not a socket exception" do
    @api.stop
    assert_raises(OpenrouterKeyClient::Error) { @client.list }
  end
end
