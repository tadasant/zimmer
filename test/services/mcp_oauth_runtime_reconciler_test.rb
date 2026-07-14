# frozen_string_literal: true

require "test_helper"

class McpOauthRuntimeReconcilerTest < ActiveSupport::TestCase
  setup do
    @credential = mcp_oauth_credentials(:notion)
    # A rotating provider: DB currently holds the token pair Zimmer last wrote,
    # with an access token good for another hour.
    @credential.update!(
      access_token: "db-access-token",
      refresh_token: "db-refresh-token",
      expires_at: 1.hour.from_now
    )
  end

  # A stand-in RuntimeMcpCredentialWriter that returns a fixed on-disk snapshot map.
  class FakeReader
    def initialize(snapshots)
      @snapshots = snapshots
    end

    def read_runtime_credentials
      @snapshots
    end
  end

  class RaisingReader
    def read_runtime_credentials
      raise "boom"
    end
  end

  def snapshot(access_token:, refresh_token:, expires_at:)
    RuntimeMcpTokenSnapshot.new(
      access_token: access_token,
      refresh_token: refresh_token,
      expires_at: expires_at
    )
  end

  def reconciler_for(entry)
    McpOauthRuntimeReconciler.new(FakeReader.new(@credential.credential_key => entry))
  end

  test "adopts a newer rotated token pair into the DB" do
    entry = snapshot(
      access_token: "runtime-access-token",
      refresh_token: "runtime-rotated-refresh-token",
      expires_at: 2.hours.from_now
    )

    assert reconciler_for(entry).reconcile!(@credential)

    @credential.reload
    assert_equal "runtime-access-token", @credential.access_token
    assert_equal "runtime-rotated-refresh-token", @credential.refresh_token
  end

  test "adopts a rotated refresh token even when the on-disk access token has already expired" do
    # This is the exact case merge_preserving_fresher! drops: the on-disk access
    # token has lapsed, but its expiry is still LATER than the DB's, meaning the
    # runtime refreshed (and rotated) after Zimmer last wrote the row. The rotated
    # refresh token is the live head of the chain regardless of the access TTL.
    @credential.update!(expires_at: 3.hours.ago)
    entry = snapshot(
      access_token: "runtime-access-token",
      refresh_token: "runtime-rotated-refresh-token",
      expires_at: 1.hour.ago
    )

    assert reconciler_for(entry).reconcile!(@credential)

    @credential.reload
    assert_equal "runtime-rotated-refresh-token", @credential.refresh_token
    assert_equal "runtime-access-token", @credential.access_token
  end

  test "does not adopt an older on-disk pair" do
    entry = snapshot(
      access_token: "stale-runtime-access",
      refresh_token: "stale-runtime-refresh",
      expires_at: 10.minutes.from_now
    )

    assert_not reconciler_for(entry).reconcile!(@credential)

    @credential.reload
    assert_equal "db-refresh-token", @credential.refresh_token
  end

  test "is a no-op when the on-disk pair is byte-identical to the DB (no updated_at churn)" do
    entry = snapshot(
      access_token: "db-access-token",
      refresh_token: "db-refresh-token",
      expires_at: 2.hours.from_now
    )
    original_updated_at = @credential.updated_at

    assert_not reconciler_for(entry).reconcile!(@credential)

    @credential.reload
    assert_equal original_updated_at.to_i, @credential.updated_at.to_i,
      "an unchanged token pair must not bump updated_at (the cron throttle keys on it)"
  end

  test "does not adopt a snapshot missing a refresh token" do
    entry = snapshot(
      access_token: "runtime-access-token",
      refresh_token: nil,
      expires_at: 5.hours.from_now
    )

    assert_not reconciler_for(entry).reconcile!(@credential)

    @credential.reload
    assert_equal "db-refresh-token", @credential.refresh_token
  end

  test "does nothing when the runtime store has no entry for the credential" do
    reconciler = McpOauthRuntimeReconciler.new(FakeReader.new({}))

    assert_not reconciler.reconcile!(@credential)

    @credential.reload
    assert_equal "db-refresh-token", @credential.refresh_token
  end

  test "matches an entry stored under an explicit runtime key" do
    runtime_key = "runtime-specific|deadbeef"
    entry = snapshot(
      access_token: "runtime-access-token",
      refresh_token: "runtime-rotated-refresh-token",
      expires_at: 2.hours.from_now
    )
    reconciler = McpOauthRuntimeReconciler.new(FakeReader.new(runtime_key => entry))

    # The credential's own key doesn't match, so nothing is adopted...
    assert_not reconciler.reconcile!(@credential)
    # ...but the explicit runtime key does.
    assert reconciler.reconcile!(@credential, runtime_key: runtime_key)

    @credential.reload
    assert_equal "runtime-rotated-refresh-token", @credential.refresh_token
  end

  test "treats an unreadable runtime store as nothing to adopt" do
    reconciler = McpOauthRuntimeReconciler.new(RaisingReader.new)

    assert_not reconciler.reconcile!(@credential)

    @credential.reload
    assert_equal "db-refresh-token", @credential.refresh_token
  end
end
