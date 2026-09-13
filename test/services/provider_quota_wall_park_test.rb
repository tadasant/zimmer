# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The timed re-check ladder a quota wall parks on when its runtime has no account
# pool. The end-to-end path through ProcessLifecycleManager, with real Pi
# transcripts, is PiRecoveryEndToEndTest; this holds the ladder, the streak and
# the ceiling down on their own.
class ProviderQuotaWallParkTest < ActiveJob::TestCase
  setup do
    @session = Session.create!(
      prompt: "Pi test prompt",
      agent_runtime: "pi",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid
    )
  end

  def park!(message = "402: {\"message\":\"Insufficient credits.\",\"code\":402}")
    ProviderQuotaWallPark.new(@session).park!(message: message)
  end

  def wake_triggers
    Trigger.where(last_session_id: @session.id, reuse_session: true)
  end

  test "the ladder doubles from fifteen minutes to eight hours, then holds" do
    assert_equal [ 15.minutes, 30.minutes, 1.hour, 2.hours, 4.hours, 8.hours, 8.hours, 8.hours ],
      (1..8).map { |n| ProviderQuotaWallPark.interval_for(n) }
  end

  test "the first park starts a streak, arms one wake, and notifies" do
    freeze_time do
      outcome = park!

      assert outcome.parked?
      assert_equal 1, outcome.park_number
      assert_equal 15.minutes.from_now, outcome.next_check_at

      streak = ProviderQuotaWallPark.streak(@session.reload)
      assert_equal Time.current.utc.iso8601, streak["started_at"]
      assert_equal 1, streak["parks"]
      assert_match(/Insufficient credits/, streak["message"])

      assert_equal 1, wake_triggers.count
      assert @session.metadata["pending_sleep"], "creating the wake marks the running session to sleep"
      assert_enqueued_jobs 1, only: SendPushNotificationJob
      assert_match(/Provider quota wall: Pi's provider refused this turn/, @session.logs.last.content)
      assert_equal "warning", @session.logs.last.level, "a park is not an error, and must not read as one"
    end
  end

  test "each later park in the streak climbs one rung, keeps its start, and does not notify again" do
    started = Time.current
    park!

    travel 16.minutes do
      @session.update!(status: :running)
      outcome = park!

      assert_equal 2, outcome.park_number
      assert_equal 30.minutes.from_now.to_i, outcome.next_check_at.to_i
      assert_equal started.utc.iso8601, ProviderQuotaWallPark.streak(@session.reload)["started_at"]
    end

    assert_enqueued_jobs 1, only: SendPushNotificationJob
  end

  test "ending the streak starts the next wall back at the bottom of the ladder" do
    park!
    park!
    assert ProviderQuotaWallPark.end_streak!(@session)
    assert_nil ProviderQuotaWallPark.streak(@session.reload)

    @session.update!(status: :running)
    assert_equal 1, park!.park_number
  end

  test "parked? is the streak and the pending sleep together" do
    assert_not ProviderQuotaWallPark.parked?(@session)
    assert_not ProviderQuotaWallPark.parked?(nil)

    park!
    assert ProviderQuotaWallPark.parked?(@session.reload)

    @session.remove_metadata!("pending_sleep")
    assert_not ProviderQuotaWallPark.parked?(@session.reload), "a streak alone outlives the turn it parked"
  end

  test "ending a streak that does not exist writes nothing" do
    @session.expects(:remove_metadata!).never

    assert_not ProviderQuotaWallPark.end_streak!(@session)
    assert_not ProviderQuotaWallPark.end_streak!(nil)
  end

  # The bound: once the next re-check would land past CEILING from the streak's
  # first park, stop arming them.
  test "at the ceiling it stops re-checking, clears the streak, and notifies" do
    @session.merge_metadata!(ProviderQuotaWallPark::METADATA_KEY => {
      "started_at" => (ProviderQuotaWallPark::CEILING - 7.hours).ago.utc.iso8601,
      "parks" => 23
    })

    outcome = park!

    assert_not outcome.parked?
    assert_nil outcome.next_check_at
    assert_equal 23, outcome.park_number
    assert_match(/re-checks stopped/, outcome.error_message)
    assert_equal 0, wake_triggers.count
    assert_nil ProviderQuotaWallPark.streak(@session.reload)
    assert_enqueued_jobs 1, only: SendPushNotificationJob
  end

  test "a re-check that still fits under the ceiling is armed" do
    @session.merge_metadata!(ProviderQuotaWallPark::METADATA_KEY => {
      "started_at" => (ProviderQuotaWallPark::CEILING - 9.hours).ago.utc.iso8601,
      "parks" => 23
    })

    assert park!.parked?
    assert_equal 1, wake_triggers.count
  end

  # A session that cannot be woken must not be left asleep on nothing: the caller
  # comes to rest in needs_input, and the sentence says what to do.
  test "a re-check that cannot be scheduled leaves the session for a human, saying so" do
    @session.update!(status: :failed)

    outcome = park!

    assert_not outcome.parked?
    assert_match(/could not schedule a re-check/, outcome.error_message)
    assert_equal 0, wake_triggers.count
    assert_match(/could not schedule a re-check/, @session.logs.last.content)
  end

  test "a corrupt streak record is treated as no streak" do
    @session.merge_metadata!(ProviderQuotaWallPark::METADATA_KEY => "not a hash")

    assert_nil ProviderQuotaWallPark.streak(@session)
    assert_equal 1, park!.park_number
  end

  test "the stored message is bounded" do
    park!("429: #{'x' * 2_000} quota exceeded")

    assert_operator ProviderQuotaWallPark.streak(@session.reload)["message"].length, :<=, ProviderQuotaWallPark::MESSAGE_LIMIT
  end
end
