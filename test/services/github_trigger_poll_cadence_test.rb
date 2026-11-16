# frozen_string_literal: true

require "test_helper"

class GithubTriggerPollCadenceTest < ActiveSupport::TestCase
  KEY = GithubTriggerPollCadence::SETTING_KEY

  setup do
    @saved = ENV[KEY]
    ENV.delete(KEY)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    @saved.nil? ? ENV.delete(KEY) : ENV[KEY] = @saved
    Rails.cache = @original_cache
  end

  def at(minutes) = GithubTriggerPollCadence.new(interval: minutes.minutes)

  test "the one-minute default keeps every tick count the poller has always used" do
    cadence = GithubTriggerPollCadence.current

    assert_equal 1.minute, cadence.interval
    assert_equal 3, cadence.removal_grace_misses
    assert_equal 5, cadence.sweeps_before_alert
    assert_equal 1.hour, cadence.streak_ttl
    assert_equal 15.minutes, cadence.liveness_threshold
  end

  test "at five minutes the windows stay about the same length in time" do
    cadence = at(5)

    assert_equal 2, cadence.removal_grace_misses, "a single miss is still never enough"
    assert_equal 2, cadence.sweeps_before_alert
    assert_equal 1.hour, cadence.streak_ttl
    assert_equal 15.minutes, cadence.liveness_threshold
  end

  test "at fifteen minutes nothing stretches to fifteen times its length" do
    cadence = at(15)

    assert_equal 2, cadence.removal_grace_misses, "15 minutes from first miss to drop, not 45"
    assert_equal 2, cadence.sweeps_before_alert, "a page after 30 minutes of degradation, not 75"
    assert_equal 1.hour, cadence.streak_ttl
    assert_equal 35.minutes, cadence.liveness_threshold
    assert_equal 4.hours, at(60).streak_ttl
  end

  test "reads the interval from the setting, and an invalid value falls back to one minute" do
    ENV[KEY] = "15"
    assert_equal 15.minutes, GithubTriggerPollCadence.current.interval

    %w[0 61 fast 1.5 -3].each do |raw|
      ENV[KEY] = raw
      assert_equal 1.minute, GithubTriggerPollCadence.current.interval, raw
    end
  end

  test "every tick is due at the default; a slower interval lets one through per interval" do
    assert GithubTriggerPollCadence.current.due?

    cadence = at(5)
    now = Time.current
    assert cadence.due?(now: now)
    cadence.record_sweep_started(now: now)

    refute cadence.due?(now: now + 1.minute)
    refute cadence.due?(now: now + 4.minutes)
    assert cadence.due?(now: now + 4.minutes + 45.seconds), "a cron tick a few seconds early is still due"
    assert cadence.due?(now: now + 5.minutes)
  end
end
