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

  # Most cases only care about the state arithmetic, so they name one number and
  # it reads as wholly executing.
  def status(running:, now: Time.current)
    split_status(on_a_worker: running, now: now)
  end

  # The split reading, which is what /inference renders.
  def split_status(on_a_worker:, awaiting: 0, asleep: 0, now: Time.current)
    FleetTopUpStatus.new(
      setting: @setting, now: now,
      turns: RunningTurns::Reading.new(
        on_a_worker: on_a_worker, awaiting_a_worker: awaiting, asleep: asleep
      )
    )
  end

  # THE CEILING CHANGE. A fleet of two on workers with five turns queued behind
  # them is a fleet of TWO: the queue is reported beside the number, never folded
  # into it, or the ceiling would bound how much work is waiting rather than how
  # much is running.
  test "turns waiting for a worker are named beside the count, not counted" do
    s = split_status(on_a_worker: 2, awaiting: 5)

    assert_equal 2, s.running_sessions
    assert_equal 5, s.awaiting_sessions
    assert s.under_ceiling?, "five queued turns must not push a fleet of two to its ceiling of three"
    assert_match(/2 sessions on a worker/, s.sentence)
    assert_match(/5 more waiting for one of the #{s.worker_slots} worker slots/, s.sentence)
    assert_match(/not counted/, s.sentence)
  end

  # With an empty queue and nobody asleep the count is the whole story, and a
  # clause saying what it leaves out is noise.
  test "the sentence stays plain when every turn has a worker and nobody is asleep" do
    s = split_status(on_a_worker: 3)

    assert_equal 3, s.running_sessions
    assert_equal 0, s.awaiting_sessions
    assert_match(/3 sessions on a worker/, s.sentence)
    assert_no_match(/not counted/, s.sentence)
  end

  # Sleepers are reported but not counted, and they are told apart from the
  # queue: a sleeper has no turn coming at all.
  test "sessions asleep on a wake are reported beside the count, not inside it" do
    s = split_status(on_a_worker: 1, awaiting: 1, asleep: 4)

    assert_equal 1, s.running_sessions
    assert_equal 4, s.asleep_sessions
    assert s.under_ceiling?, "four sleepers must not push a fleet of one to its ceiling of three"
    assert_match(/1 more waiting for one of the #{s.worker_slots} worker slots, 4 asleep on a wake/, s.sentence)
  end

  # The sleepers are worth saying even on a fleet whose every turn has a worker:
  # they are the difference between the number here and the row count an
  # operator sees on the dashboard.
  test "the sentence names sleepers even when nothing is waiting for a worker" do
    s = split_status(on_a_worker: 2, asleep: 3)

    assert_equal 2, s.running_sessions
    assert_match(/3 asleep on a wake — not counted/, s.sentence)
    assert_no_match(/waiting for one of/, s.sentence)
  end

  test "the worker pool ceiling is the agents lane's own thread count" do
    assert_equal ConnectionBudget.good_job_queue_threads[:agents], split_status(on_a_worker: 0).worker_slots
  end

  # The consequence of counting worker occupancy alone, which the card renders:
  # a ceiling above the pool is one the fleet can never reach.
  test "a ceiling above the worker pool is reported as out of reach" do
    slots = split_status(on_a_worker: 0).worker_slots

    @setting.update!(fleet_idle_max_sessions: slots + 2)
    over = split_status(on_a_worker: 0)
    assert over.ceiling_out_of_reach?
    assert_equal slots, over.effective_ceiling

    @setting.update!(fleet_idle_max_sessions: slots)
    at = split_status(on_a_worker: 0)
    assert_not at.ceiling_out_of_reach?
    assert_equal slots, at.effective_ceiling
  end

  test "a reading with everything on a worker reports nothing left out" do
    s = status(running: 2)

    assert_equal 2, s.running_sessions
    assert_equal 0, s.awaiting_sessions
    assert_equal 0, s.asleep_sessions
  end

  test "a fleet at its ceiling has no clock running toward a fire" do
    s = status(running: 3)

    assert_not s.under_ceiling?
    assert_equal 0, s.headroom
    assert_equal :at_ceiling, s.state
    assert_nil s.next_fire_at
  end

  test "under the ceiling with no clock started, the fire is a threshold away" do
    now = Time.current
    s = status(running: 1, now: now)

    assert s.under_ceiling?
    assert_equal 2, s.headroom
    assert_equal :clock_not_started, s.state
    assert_equal (now + 5.minutes).to_i, s.next_fire_at.to_i
  end

  # The state the fleet spends most of an hour in after every fire: `record_busy!`
  # clears `fleet_idle_since` when the spawned session runs, but deliberately
  # leaves the cooldown clock alone. Answering "the threshold" here would
  # under-report the next fire by up to 55 minutes.
  test "with no clock started but an unspent cooldown, the cooldown is the answer" do
    now = Time.current
    @setting.update!(fleet_idle_since: nil, fleet_idle_event_fired_at: now - 5.minutes)
    s = status(running: 1, now: now)

    assert_equal :clock_not_started, s.state
    assert_equal (now + 55.minutes).to_i, s.next_fire_at.to_i,
      "the threshold is the smaller of the two clocks and the wrong one"
    assert_match(/cooldown/, s.sentence)
  end

  test "inside the threshold with an unspent cooldown, the sentence names both clocks" do
    now = Time.current
    @setting.update!(fleet_idle_since: now - 2.minutes, fleet_idle_event_fired_at: now - 30.minutes)
    s = status(running: 1, now: now)

    assert_equal :inside_threshold, s.state
    assert_equal (now + 30.minutes).to_i, s.next_fire_at.to_i
    assert_match(/cooldown/, s.sentence)
  end

  test "inside the threshold, the fire is due when the stretch completes" do
    now = Time.current
    @setting.update!(fleet_idle_since: now - 2.minutes)
    s = status(running: 0, now: now)

    assert_equal :inside_threshold, s.state
    assert_equal (now + 3.minutes).to_i, s.next_fire_at.to_i
  end

  # The latch: this stretch has had its fire, and only the fleet reaching its
  # ceiling again starts another.
  test "a stretch that already fired is latched, with no clock running" do
    now = Time.current
    @setting.update!(fleet_idle_since: now - 30.minutes, fleet_idle_event_fired_at: now - 25.minutes)
    s = status(running: 0, now: now)

    assert_equal :latched, s.state
    assert_nil s.next_fire_at
  end

  # The cooldown: a NEW stretch, past its threshold, held only by the floor
  # between two fires. This is the state a fleet under a ceiling above 1 spends
  # most of its time in.
  test "a new stretch past the threshold waits out the cooldown" do
    now = Time.current
    @setting.update!(fleet_idle_since: now - 10.minutes, fleet_idle_event_fired_at: now - 20.minutes)
    s = status(running: 1, now: now)

    assert_equal :cooling_down, s.state
    assert_equal (now + 40.minutes).to_i, s.next_fire_at.to_i
  end

  test "past both the threshold and the cooldown, the fire is due" do
    now = Time.current
    @setting.update!(fleet_idle_since: now - 90.minutes, fleet_idle_event_fired_at: now - 120.minutes)
    s = status(running: 1, now: now)

    assert_equal :due, s.state
    assert_equal now.to_i, s.next_fire_at.to_i
  end

  test "max_fires_per_day is the cooldown expressed the way an operator retunes it" do
    assert_equal 24, status(running: 0).max_fires_per_day

    @setting.update!(fleet_idle_min_fire_interval_minutes: 15)
    assert_equal 96, status(running: 0).max_fires_per_day
  end

  # A cooldown over a day is a legal setting, and integer division makes the
  # per-day figure 0 there — which reads as "never" and is wrong. The phrase is
  # what the card and `get_spot_policy` print, so it has to hold at any setting.
  test "cadence_phrase stays honest at a cooldown longer than a day" do
    assert_equal "at most 24 top-ups a day", status(running: 0).cadence_phrase

    @setting.update!(fleet_idle_min_fire_interval_minutes: 1)
    assert_equal "at most 1440 top-ups a day", status(running: 0).cadence_phrase

    @setting.update!(fleet_idle_min_fire_interval_minutes: 2880)
    s = status(running: 0)
    assert_equal 0, s.max_fires_per_day
    assert_equal "at most once every 2 days", s.cadence_phrase
  end

  test "headroom is the room left under the ceiling, floored at zero" do
    assert_equal 3, status(running: 0).headroom
    assert_equal 1, status(running: 2).headroom
    assert_equal 0, status(running: 9).headroom
  end

  # Every state an operator can land in has to say something. A nil here is a
  # card that renders a blank line where the explanation should be.
  test "every state has a sentence" do
    now = Time.current
    seen = FleetTopUpStatus::STATES.to_h do |state|
      case state
      when :at_ceiling
        @setting.update!(fleet_idle_since: nil, fleet_idle_event_fired_at: nil)
        [ state, status(running: 3, now: now) ]
      when :clock_not_started
        @setting.update!(fleet_idle_since: nil, fleet_idle_event_fired_at: nil)
        [ state, status(running: 0, now: now) ]
      when :inside_threshold
        @setting.update!(fleet_idle_since: now - 1.minute, fleet_idle_event_fired_at: nil)
        [ state, status(running: 0, now: now) ]
      when :latched
        @setting.update!(fleet_idle_since: now - 30.minutes, fleet_idle_event_fired_at: now - 25.minutes)
        [ state, status(running: 0, now: now) ]
      when :cooling_down
        @setting.update!(fleet_idle_since: now - 10.minutes, fleet_idle_event_fired_at: now - 20.minutes)
        [ state, status(running: 0, now: now) ]
      when :due
        @setting.update!(fleet_idle_since: now - 90.minutes, fleet_idle_event_fired_at: now - 120.minutes)
        [ state, status(running: 0, now: now) ]
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

    assert_equal FleetIdleMonitor.running_sessions,
                 FleetTopUpStatus.current(setting: @setting).running_sessions
  end
end
