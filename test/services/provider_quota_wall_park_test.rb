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

  test "parked? holds until the re-check is due, and not after" do
    assert_not ProviderQuotaWallPark.parked?(@session)
    assert_not ProviderQuotaWallPark.parked?(nil)

    park!
    @session.reload
    assert ProviderQuotaWallPark.parked?(@session)

    # `sleep!` consumes pending_sleep; the park is still a park.
    @session.remove_metadata!("pending_sleep")
    assert ProviderQuotaWallPark.parked?(@session.reload)

    assert_not ProviderQuotaWallPark.parked?(@session, now: 16.minutes.from_now),
      "a streak outlives the turn it parked, but a due re-check is owed its turn"
  end

  # A wall that arrives long after the streak's re-check was due is not that
  # re-check: whatever ran since was a different turn, and it must not inherit the
  # old streak's rung — or its ceiling, which would stop re-checks on the first park.
  test "a streak whose re-check was due long ago is not continued" do
    @session.merge_metadata!(ProviderQuotaWallPark::METADATA_KEY => {
      "started_at" => 10.days.ago.utc.iso8601,
      "parks" => 9,
      "next_check_at" => (ProviderQuotaWallPark::STALE_AFTER + 1.minute).ago.utc.iso8601
    })

    outcome = park!

    assert outcome.parked?, "a fresh wall must not open at the ceiling"
    assert_equal 1, outcome.park_number
    assert_in_delta Time.current.to_i, Time.iso8601(ProviderQuotaWallPark.streak(@session.reload)["started_at"]).to_i, 5
    assert_enqueued_jobs 1, only: SendPushNotificationJob
  end

  test "a streak with no readable due time is not continued" do
    @session.merge_metadata!(ProviderQuotaWallPark::METADATA_KEY => { "started_at" => 10.days.ago.utc.iso8601, "parks" => 9 })

    assert_equal 1, park!.park_number
  end

  # A session a human resumed early, whose turn then completed, must not be handed
  # a quota-wall nudge hours later. A re-check that already fired is held for the
  # turn it woke and retired by the state machine, so it is left alone.
  test "ending the streak withdraws a re-check that has not fired, and only that" do
    park!
    trigger_id = ProviderQuotaWallPark.streak(@session.reload)["wake_trigger_id"]
    assert Trigger.exists?(trigger_id)

    assert ProviderQuotaWallPark.end_streak!(@session)
    assert_not Trigger.exists?(trigger_id)

    @session.update!(status: :running)
    park!
    fired_id = ProviderQuotaWallPark.streak(@session.reload)["wake_trigger_id"]
    Trigger.where(id: fired_id).update_all(wake_held_at: Time.current)

    ProviderQuotaWallPark.end_streak!(@session)
    assert Trigger.exists?(fired_id), "a fired wake is the state machine's to retire"
  end

  # Resumed early by a message and refused again: the old re-check is replaced,
  # not joined by a second one.
  test "a re-park replaces a re-check that has not fired" do
    park!
    first_id = ProviderQuotaWallPark.streak(@session.reload)["wake_trigger_id"]

    @session.update!(status: :running)
    park!

    assert_not Trigger.exists?(first_id)
    assert_equal 1, wake_triggers.count
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
      "parks" => 23,
      "next_check_at" => Time.current.utc.iso8601
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
      "parks" => 23,
      "next_check_at" => Time.current.utc.iso8601
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
    assert_nil ProviderQuotaWallPark.streak(@session.reload), "no record may claim a re-check that does not exist"
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
