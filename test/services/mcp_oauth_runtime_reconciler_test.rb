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

  # A stand-in RuntimeMcpCredentialWriter for a listable store (Claude Code,
  # Codex): it returns the whole map however it is asked, and counts reads so a
  # test can assert the reconciler reads it once.
  class FakeReader
    attr_reader :reads, :requested

    def initialize(snapshots)
      @snapshots = snapshots
      @reads = 0
      @requested = []
    end

    def enumerable_store? = true

    def read_runtime_credentials(credential_keys = nil)
      @reads += 1
      @requested << credential_keys
      @snapshots
    end
  end

  # A stand-in for a probe-only store (Pi): it can only answer for keys it is
  # given, and answers {} when asked to enumerate.
  class FakeProbeReader
    attr_reader :reads, :requested

    def initialize(snapshots)
      @snapshots = snapshots
      @reads = 0
      @requested = []
    end

    def enumerable_store? = false

    def read_runtime_credentials(credential_keys = nil)
      @reads += 1
      @requested << credential_keys
      @snapshots.slice(*Array(credential_keys))
    end
  end

  class RaisingReader
    attr_reader :reads

    def initialize = @reads = 0

    def read_runtime_credentials(_credential_keys = nil)
      @reads += 1
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

  test "does not adopt over a DB row with no expiry" do
    # A nil expires_at means the provider issued no `expires_in`, so the access
    # token does not expire — and a non-expiring token is one no runtime ever
    # refreshes. The runtime's copy therefore cannot legitimately be ahead, and
    # reading "the runtime recorded an expiry and we did not" as newer would let a
    # stale on-disk pair overwrite a freshly authorized one.
    @credential.update!(expires_at: nil)
    entry = snapshot(
      access_token: "pre-reauth-access",
      refresh_token: "pre-reauth-revoked-refresh",
      expires_at: 2.hours.from_now
    )

    assert_not reconciler_for(entry).reconcile!(@credential)

    @credential.reload
    assert_equal "db-refresh-token", @credential.refresh_token
  end

  test "does not adopt an entry recorded against a different server URL" do
    # Pi keys its store by the bare server name, and server_name is not unique
    # across rows — a server whose URL changed leaves the old row behind, and both
    # rows probe the same keyring account.
    entry = RuntimeMcpTokenSnapshot.new(
      access_token: "other-row-access",
      refresh_token: "other-row-refresh",
      expires_at: 2.hours.from_now,
      server_url: "https://mcp.notion.com/some-other-endpoint"
    )

    assert_not reconciler_for(entry).reconcile!(@credential)

    @credential.reload
    assert_equal "db-refresh-token", @credential.refresh_token
  end

  test "adopts an entry whose recorded server URL matches" do
    entry = RuntimeMcpTokenSnapshot.new(
      access_token: "runtime-access-token",
      refresh_token: "runtime-rotated-refresh-token",
      expires_at: 2.hours.from_now,
      server_url: @credential.server_url
    )

    assert reconciler_for(entry).reconcile!(@credential)

    @credential.reload
    assert_equal "runtime-rotated-refresh-token", @credential.refresh_token
  end

  test "a listable store is read once and reused across credentials" do
    entry = snapshot(
      access_token: "runtime-access-token",
      refresh_token: "runtime-rotated-refresh-token",
      expires_at: 2.hours.from_now
    )
    reader = FakeReader.new(@credential.credential_key => entry)
    reconciler = McpOauthRuntimeReconciler.new(reader)

    assert_equal 0, reader.reads, "constructing a reconciler must not touch the store"

    reconciler.reconcile!(@credential)
    reconciler.reconcile!(@credential, runtime_key: "some-other-key")

    assert_equal 1, reader.reads
    assert_equal [ nil ], reader.requested, "a listable store is asked to enumerate"
  end

  test "a probe-only store is asked for exactly the keys wanted, once each" do
    # Pi's OS credential store has no listing, so the reconciler probes it by
    # key. Each key costs one probe no matter how many credentials ask for it.
    entry = snapshot(
      access_token: "runtime-access-token",
      refresh_token: "runtime-rotated-refresh-token",
      expires_at: 2.hours.from_now
    )
    reader = FakeProbeReader.new("notion" => entry)
    reconciler = McpOauthRuntimeReconciler.new(reader)

    assert reconciler.reconcile!(@credential, runtime_key: "notion")
    assert_not reconciler.reconcile!(@credential, runtime_key: "notion")
    reconciler.reconcile!(@credential, runtime_key: "linear")

    assert_equal [ [ "notion" ], [ "linear" ] ], reader.requested

    @credential.reload
    assert_equal "runtime-rotated-refresh-token", @credential.refresh_token
  end

  test "a probe-only store that never answers is asked once per key, not once per credential" do
    reader = RaisingReader.new
    reader.define_singleton_method(:enumerable_store?) { false }
    reconciler = McpOauthRuntimeReconciler.new(reader)

    3.times { assert_not reconciler.reconcile!(@credential, runtime_key: "notion") }

    assert_equal 1, reader.reads
  end

  test "swallows a lock or update failure and returns false without raising" do
    # A hot row under concurrent sessions + the cron can raise Deadlocked /
    # LockWaitTimeout from with_lock. Reconciliation is best-effort: it must not
    # propagate (which would fail a spawn or page the alert channel), leaving the
    # DB copy untouched for the next attempt.
    entry = snapshot(
      access_token: "runtime-access-token",
      refresh_token: "runtime-rotated-refresh-token",
      expires_at: 2.hours.from_now
    )
    @credential.define_singleton_method(:with_lock) do |*|
      raise ActiveRecord::Deadlocked, "deadlock detected"
    end

    result = nil
    assert_nothing_raised { result = reconciler_for(entry).reconcile!(@credential) }
    assert_not result
  end
end
