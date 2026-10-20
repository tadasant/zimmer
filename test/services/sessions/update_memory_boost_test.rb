# frozen_string_literal: true

require "test_helper"

module Sessions
  class UpdateMemoryBoostTest < ActiveSupport::TestCase
    setup do
      @previous_limit = ENV["ZIMMER_SESSION_MEMORY_MAX_MB"]
      ENV["ZIMMER_SESSION_MEMORY_MAX_MB"] = "4096"
      @session = sessions(:running)
      @now = Time.zone.parse("2026-10-20T01:00:00Z")
    end

    teardown do
      @previous_limit.nil? ? ENV.delete("ZIMMER_SESSION_MEMORY_MAX_MB") : ENV["ZIMMER_SESSION_MEMORY_MAX_MB"] = @previous_limit
    end

    test "grants a boost with the default duration and logs it" do
      assert_difference -> { @session.logs.count }, 1 do
        UpdateMemoryBoost.grant(session: @session, memory_mb: "6144", now: @now)
      end

      @session.reload
      assert_equal 6144, @session.memory_boost_mb
      assert_equal @now + SessionMemoryBoost::DEFAULT_HOURS.hours, @session.memory_boost_expires_at
      assert @session.memory_boost_active?(now: @now)
      assert_match(/Memory boost granted: 6144 MB/, @session.logs.order(:id).last.content)
    end

    test "takes an explicit duration" do
      UpdateMemoryBoost.grant(session: @session, memory_mb: 5000, hours: 2, now: @now)

      assert_equal @now + 2.hours, @session.reload.memory_boost_expires_at
    end

    test "refuses a boost no bigger than the ordinary limit, or past the sanity bound" do
      assert_raises(UpdateMemoryBoost::OutOfRange) { UpdateMemoryBoost.grant(session: @session, memory_mb: 4096) }
      assert_raises(UpdateMemoryBoost::OutOfRange) do
        UpdateMemoryBoost.grant(session: @session, memory_mb: SessionMemoryBoost::MAX_MB + 1)
      end
    end

    test "refuses a duration outside 1..MAX_HOURS and values that are not integers" do
      assert_raises(UpdateMemoryBoost::OutOfRange) { UpdateMemoryBoost.grant(session: @session, memory_mb: 6144, hours: 0) }
      assert_raises(UpdateMemoryBoost::OutOfRange) do
        UpdateMemoryBoost.grant(session: @session, memory_mb: 6144, hours: SessionMemoryBoost::MAX_HOURS + 1)
      end
      assert_raises(UpdateMemoryBoost::InvalidParameter) { UpdateMemoryBoost.grant(session: @session, memory_mb: "6g") }
      assert_raises(UpdateMemoryBoost::InvalidParameter) { UpdateMemoryBoost.grant(session: @session, memory_mb: nil) }
    end

    test "refuses an archived session" do
      archived = sessions(:archived)

      assert_raises(UpdateMemoryBoost::Refused) { UpdateMemoryBoost.grant(session: archived, memory_mb: 6144) }
    end

    test "one boost at a time, and the refusal names the holder" do
      holder = sessions(:needs_input)
      UpdateMemoryBoost.grant(session: holder, memory_mb: 6144, now: @now)

      error = assert_raises(UpdateMemoryBoost::Refused) do
        UpdateMemoryBoost.grant(session: @session, memory_mb: 6144, now: @now)
      end
      assert_match(/Session #{holder.id} already holds a memory boost/, error.message)
    end

    test "re-granting the holder replaces its size and expiry" do
      UpdateMemoryBoost.grant(session: @session, memory_mb: 6144, now: @now)
      UpdateMemoryBoost.grant(session: @session, memory_mb: 5000, hours: 1, now: @now)

      assert_equal 5000, @session.reload.memory_boost_mb
      assert_equal @now + 1.hour, @session.memory_boost_expires_at
    end

    test "an expired boost does not block another session" do
      sessions(:needs_input).update_columns(memory_boost_mb: 6144, memory_boost_expires_at: @now - 1.minute)

      UpdateMemoryBoost.grant(session: @session, memory_mb: 6144, now: @now)

      assert_equal 6144, @session.reload.memory_boost_mb
    end

    test "clear ends the boost and logs it; clearing nothing is a no-op" do
      UpdateMemoryBoost.grant(session: @session, memory_mb: 6144, now: @now)

      UpdateMemoryBoost.clear(session: @session)
      assert_nil @session.reload.memory_boost_mb
      assert_nil @session.memory_boost_expires_at

      assert_no_difference -> { @session.logs.count } do
        UpdateMemoryBoost.clear(session: @session)
      end
    end
  end
end
