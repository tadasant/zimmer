# frozen_string_literal: true

require "test_helper"

class PiProviderKeyJobsTest < ActiveJob::TestCase
  setup do
    @api = FakeOpenrouterKeysApi.start
    @client = @api.client
  end

  teardown { @api.stop }

  def key_for(session_id, created_at: 1.hour.ago, expires_at: 1.day.from_now, name: "#{PiSessionKeys.name_prefix}x")
    PiProviderKey.create!(session_id: session_id, key_hash: @api.seed_key(name: name, created_at: created_at),
                          name: name, limit_usd: 20, expires_at: expires_at, created_at: created_at, updated_at: created_at)
  end

  # --- revoke job ------------------------------------------------------------

  test "the revoke job deletes the session's keys minted before the cutoff" do
    session = sessions(:needs_input)
    old = key_for(session.id, created_at: 5.minutes.ago)
    newer = key_for(session.id, created_at: Time.current)

    PiSessionKeys.stub(:client, @client) do
      PiProviderKeyRevokeJob.perform_now(session.id, 1.minute.ago.iso8601(6), "session_at_rest")
    end

    assert_equal "session_at_rest", old.reload.revoke_reason
    assert_nil newer.reload.revoked_at
  end

  test "the revoke job without a management key leaves keys to expire" do
    record = key_for(sessions(:needs_input).id)

    PiSessionKeys.stub(:client, nil) do
      PiProviderKeyRevokeJob.perform_now(record.session_id, Time.current.iso8601(6), "session_at_rest")
    end

    assert_nil record.reload.revoked_at
  end

  # --- sweep -----------------------------------------------------------------

  test "the sweep revokes expired, at-rest and gone keys, and leaves live and fresh ones" do
    expired = key_for(sessions(:running).id, expires_at: 1.minute.ago)
    at_rest = key_for(sessions(:archived).id)
    gone = key_for(-1)
    live = key_for(sessions(:running).id)
    fresh = key_for(sessions(:archived).id, created_at: 1.minute.ago)

    PiProviderKeySweepJob.perform_now(client: @client)

    assert_equal "expired", expired.reload.revoke_reason
    assert_equal "session_at_rest", at_rest.reload.revoke_reason
    assert_equal "session_gone", gone.reload.revoke_reason
    assert_nil live.reload.revoked_at
    assert_nil fresh.reload.revoked_at
  end

  test "the sweep leaves a key alone while its session is blocked on an elicitation" do
    session = sessions(:needs_input)
    session.update_column(:metadata, (session.metadata || {}).merge("blocked_on_elicitation" => true))
    record = key_for(session.id)

    PiProviderKeySweepJob.perform_now(client: @client)

    assert_nil record.reload.revoked_at
  end

  test "the sweep deletes only its own orphans, and only once they are past the grace" do
    orphan = @api.seed_key(name: "#{PiSessionKeys.name_prefix}s1-old", created_at: 1.hour.ago)
    recent = @api.seed_key(name: "#{PiSessionKeys.name_prefix}s2-new", created_at: 1.minute.ago)
    foreign = @api.seed_key(name: "someone-elses-key", created_at: 1.day.ago)
    other_deployment = @api.seed_key(name: "zimmer-pi-0000000000-s3", created_at: 1.day.ago)

    PiSessionKeys.stub(:mode, "on") { PiProviderKeySweepJob.perform_now(client: @client) }

    assert_equal [ recent, foreign, other_deployment ].sort, @api.live_hashes.sort
    refute_includes @api.live_hashes, orphan
  end

  test "with the feature off and nothing minted, the sweep asks OpenRouter nothing" do
    PiProviderKeySweepJob.perform_now(client: @client)

    assert_empty @api.calls
  end

  # --- the at-rest hook ------------------------------------------------------

  test "a session leaving running with a minted key enqueues a revoke" do
    session = sessions(:running)
    key_for(session.id)

    assert_enqueued_with(job: PiProviderKeyRevokeJob) do
      session.update!(status: :needs_input)
    end
  end

  test "a session with no minted key enqueues nothing" do
    assert_no_enqueued_jobs(only: PiProviderKeyRevokeJob) do
      sessions(:running).update!(status: :needs_input)
    end
  end

  test "an elicitation block keeps the key" do
    session = sessions(:running)
    key_for(session.id)

    assert_no_enqueued_jobs(only: PiProviderKeyRevokeJob) do
      session.block_on_elicitation!
    end
    assert_predicate session.reload, :blocked_on_elicitation?
  end

  test "a revoke job that finds the session live again leaves its keys" do
    session = sessions(:running)
    record = key_for(session.id, created_at: 5.minutes.ago)

    PiSessionKeys.stub(:client, @client) do
      PiProviderKeyRevokeJob.perform_now(session.id, 1.minute.ago.iso8601(6), "session_at_rest")
    end

    assert_nil record.reload.revoked_at
  end

  test "a second revoke of the same key does not overwrite the spend the first recorded" do
    record = key_for(sessions(:archived).id)
    @api.set_usage(record.key_hash, 2.5)
    stale = PiProviderKey.find(record.id)

    assert PiSessionKeys.revoke!(record, reason: "session_at_rest", client: @client)
    assert PiSessionKeys.revoke!(stale, reason: "expired", client: @client)

    record.reload
    assert_equal "session_at_rest", record.revoke_reason
    assert_equal BigDecimal("2.5"), record.usage_usd
  end

  test "the sweep touches the rows it skips, so live sessions cannot starve the rest" do
    live = key_for(sessions(:running).id, created_at: 2.hours.ago)
    stub_const_batch(1) do
      PiProviderKeySweepJob.perform_now(client: @client)
    end
    assert_operator live.reload.updated_at, :>, 1.minute.ago

    at_rest = key_for(sessions(:archived).id, created_at: 1.hour.ago)
    stub_const_batch(1) do
      PiProviderKeySweepJob.perform_now(client: @client)
    end
    assert_equal "session_at_rest", at_rest.reload.revoke_reason
  end

  def stub_const_batch(size)
    original = PiProviderKeySweepJob::BATCH
    PiProviderKeySweepJob.send(:remove_const, :BATCH)
    PiProviderKeySweepJob.const_set(:BATCH, size)
    yield
  ensure
    PiProviderKeySweepJob.send(:remove_const, :BATCH)
    PiProviderKeySweepJob.const_set(:BATCH, original)
  end
end
