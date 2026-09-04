# frozen_string_literal: true

require "test_helper"

# The reading /inference and `get_spot_policy` both render. What it exists to
# pin is that the four ways "it has not fired" can be true are told apart, since
# they look identical from outside and clear four different ways.
class FleetTopUpStatusTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    Session.delete_all
    @setting = AppSetting.editable
    @setting.update!(fleet_idle_since: nil, fleet_idle_event_fired_at: nil,
                     fleet_idle_max_sessions: 3, fleet_idle_threshold_minutes: 5,
                     fleet_idle_min_fire_interval_minutes: 60)
  end

  def status(in_hand:, now: Time.current)
    FleetTopUpStatus.new(setting: @setting, sessions_in_hand: in_hand, now: now)
  end

  test "a fleet at its ceiling has no clock running toward a fire" do
    s = status(in_hand: 3)

    assert_not s.under_ceiling?
    assert_equal 0, s.headroom
    assert_equal :at_ceiling, s.state
    assert_nil s.next_fire_at
  end

  test "under the ceiling with no clock started, the fire is a threshold away" do
    now = Time.current
    s = status(in_hand: 1, now: now)

    assert s.under_ceiling?
    assert_equal 2, s.headroom
    assert_equal :clock_not_started, s.state
    assert_equal (now + 5.minutes).to_i, s.next_fire_at.to_i
  end

  test "inside the threshold, the fire is due when the stretch completes" do
    now = Time.current
    @setting.update!(fleet_idle_since: now - 2.minutes)
    s = status(in_hand: 0, now: now)

    assert_equal :inside_threshold, s.state
    assert_equal (now + 3.minutes).to_i, s.next_fire_at.to_i
  end

  # The latch: this stretch has had its fire, and only the fleet reaching its
  # ceiling again starts another.
  test "a stretch that already fired is latched, with no clock running" do
    now = Time.current
    @setting.update!(fleet_idle_since: now - 30.minutes, fleet_idle_event_fired_at: now - 25.minutes)
    s = status(in_hand: 0, now: now)

    assert_equal :latched, s.state
    assert_nil s.next_fire_at
  end

  # The cooldown: a NEW stretch, past its threshold, held only by the floor
  # between two fires. This is the state a fleet under a ceiling above 1 spends
  # most of its time in.
  test "a new stretch past the threshold waits out the cooldown" do
    now = Time.current
    @setting.update!(fleet_idle_since: now - 10.minutes, fleet_idle_event_fired_at: now - 20.minutes)
    s = status(in_hand: 1, now: now)

    assert_equal :cooling_down, s.state
    assert_equal (now + 40.minutes).to_i, s.next_fire_at.to_i
  end

  test "past both the threshold and the cooldown, the fire is due" do
    now = Time.current
    @setting.update!(fleet_idle_since: now - 90.minutes, fleet_idle_event_fired_at: now - 120.minutes)
    s = status(in_hand: 1, now: now)

    assert_equal :due, s.state
    assert_equal now.to_i, s.next_fire_at.to_i
  end

  test "max_fires_per_day is the cooldown expressed the way an operator retunes it" do
    assert_equal 24, status(in_hand: 0).max_fires_per_day

    @setting.update!(fleet_idle_min_fire_interval_minutes: 15)
    assert_equal 96, status(in_hand: 0).max_fires_per_day
  end

  # Every state an operator can land in has to say something. A nil here is a
  # card that renders a blank line where the explanation should be.
  test "every state has a sentence" do
    now = Time.current
    seen = FleetTopUpStatus::STATES.to_h do |state|
      case state
      when :at_ceiling
        @setting.update!(fleet_idle_since: nil, fleet_idle_event_fired_at: nil)
        [ state, status(in_hand: 3, now: now) ]
      when :clock_not_started
        @setting.update!(fleet_idle_since: nil, fleet_idle_event_fired_at: nil)
        [ state, status(in_hand: 0, now: now) ]
      when :inside_threshold
        @setting.update!(fleet_idle_since: now - 1.minute, fleet_idle_event_fired_at: nil)
        [ state, status(in_hand: 0, now: now) ]
      when :latched
        @setting.update!(fleet_idle_since: now - 30.minutes, fleet_idle_event_fired_at: now - 25.minutes)
        [ state, status(in_hand: 0, now: now) ]
      when :cooling_down
        @setting.update!(fleet_idle_since: now - 10.minutes, fleet_idle_event_fired_at: now - 20.minutes)
        [ state, status(in_hand: 0, now: now) ]
      when :due
        @setting.update!(fleet_idle_since: now - 90.minutes, fleet_idle_event_fired_at: now - 120.minutes)
        [ state, status(in_hand: 0, now: now) ]
      end
    end

    seen.each do |expected, s|
      assert_equal expected, s.state
      assert s.sentence.present?, "#{expected} has no sentence"
    end
  end

  # The page and the tool must not take two readings a moment apart.
  test "current reads the live fleet through the monitor" do
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "work",
                    genesis: SessionGenesis::GITHUB_ISSUE, status: :running,
                    session_id: "cli-#{SecureRandom.hex(4)}")

    assert_equal FleetIdleMonitor.sessions_in_hand,
                 FleetTopUpStatus.current(setting: @setting).sessions_in_hand
  end
end
