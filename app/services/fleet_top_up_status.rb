# frozen_string_literal: true

# One reading of everything FleetIdleMonitor decides on, so the /inference card
# and `get_spot_policy` describe the same fleet in the same words rather than
# taking two readings a moment apart.
#
# Four states look identical from outside — "it has not fired" — and clear in four
# different ways: the fleet is over its ceiling, the stretch is inside the
# threshold, this stretch is latched, or the cooldown is unspent. This names which
# one the monitor is in, and when the next fire is due.
#
# Read-only. It never advances a clock and never fires anything; the monitor owns
# both, and a page render must not be able to spawn a session.
class FleetTopUpStatus
  # Ordered the way `check!` reaches them, which is also the order they resolve
  # in: a fleet over its ceiling has not started a clock, a clock that has not
  # crossed the threshold has not reached the latch, and so on.
  STATES = %i[at_ceiling clock_not_started inside_threshold latched cooling_down due].freeze

  attr_reader :setting, :sessions_in_hand, :max_sessions, :threshold, :min_fire_interval,
    :idle_since, :last_fired_at, :now

  def self.current(setting: AppSetting.current, now: Time.current)
    new(setting: setting, sessions_in_hand: FleetIdleMonitor.sessions_in_hand, now: now)
  end

  def initialize(setting:, sessions_in_hand:, now: Time.current)
    @setting = setting
    @sessions_in_hand = sessions_in_hand
    @now = now
    @max_sessions = FleetIdleMonitor.max_sessions(setting)
    @threshold = FleetIdleMonitor.idle_threshold(setting)
    @min_fire_interval = FleetIdleMonitor.min_fire_interval(setting)
    @idle_since = setting.fleet_idle_since
    @last_fired_at = setting.fleet_idle_event_fired_at
  end

  # Whether the fleet is holding few enough sessions to count as idle. Only the
  # first of the monitor's three questions — a fleet under its ceiling can still
  # be held off by an auth-outage park or an empty account pool, both of which
  # the rest of this page already reports in their own words.
  def under_ceiling?
    sessions_in_hand < max_sessions
  end

  # How much room is left before the fleet stops counting as idle enough.
  def headroom
    [ max_sessions - sessions_in_hand, 0 ].max
  end

  def state
    return :at_ceiling unless under_ceiling?
    return :clock_not_started if idle_since.nil?
    return :inside_threshold if now - idle_since < threshold
    # The latch: this stretch has already had its fire, and only the fleet
    # reaching its ceiling again moves `fleet_idle_since` past it.
    return :latched if last_fired_at.present? && last_fired_at >= idle_since
    return :cooling_down if last_fired_at.present? && now - last_fired_at < min_fire_interval

    :due
  end

  # The earliest moment the event could fire, or nil when no clock is running
  # toward one — because the fleet is over its ceiling, or because this stretch
  # is latched and needs the fleet to get busy before it counts again.
  #
  # Both clocks are consulted in every branch that has them. The threshold alone
  # is the wrong answer for most of the interval after a fire: `record_busy!`
  # clears `fleet_idle_since` when the spawned session runs but deliberately
  # leaves `fleet_idle_event_fired_at` alone, so `clock_not_started` with an
  # unspent cooldown is the ORDINARY state for the rest of that hour, not an
  # exotic one — and answering "5 minutes" there under-reports by up to 55.
  #
  # An estimate by construction: the fleet can reach its ceiling at any moment
  # and put every clock back.
  def next_fire_at
    case state
    when :at_ceiling, :latched then nil
    when :due then now
    when :clock_not_started then [ now + threshold, cooldown_ends_at ].compact.max
    else [ idle_since + threshold, cooldown_ends_at ].compact.max
    end
  end

  # When the floor between two fires is spent, or nil when nothing has fired yet.
  def cooldown_ends_at
    last_fired_at && last_fired_at + min_fire_interval
  end

  # Whether a previous fire's cooldown is still running. The threshold is not the
  # whole answer whenever this is true.
  def cooldown_pending?
    cooldown_ends_at.present? && cooldown_ends_at > now
  end

  # How often the event can fire at its very fastest, given the cooldown. The
  # number an operator is really retuning when they change the interval, and the
  # one the ceiling stops capping as soon as it is above 1.
  #
  # Zero for any cooldown longer than a day, which is a legal setting — read it
  # through #cadence_phrase rather than printing it, since "0 a day" reads as
  # "never" and is wrong.
  def max_fires_per_day
    (1.day / min_fire_interval).floor
  end

  # The cadence in words, at any legal cooldown. Per day while that is a number
  # above zero, and as the interval itself once a day no longer divides it —
  # normalised through Duration.build so a 2880-minute cooldown reads "2 days"
  # rather than as the raw minutes the operator typed.
  def cadence_phrase
    return "at most once every #{ActiveSupport::Duration.build(min_fire_interval.to_i).inspect}" if max_fires_per_day < 1

    "at most #{max_fires_per_day} #{"top-up".pluralize(max_fires_per_day)} a day"
  end

  def sentence
    case state
    when :at_ceiling
      "The fleet is holding #{sessions} — at or over its ceiling of #{max_sessions}, so no top-up is due. " \
        "The clock starts again when it drops below #{max_sessions}."
    when :clock_not_started
      "The fleet is holding #{sessions}, under its ceiling of #{max_sessions}. The idle clock starts at " \
        "the next check, and the event is due #{threshold.inspect} after that.#{cooldown_clause}"
    when :inside_threshold
      "The fleet has been under its ceiling of #{max_sessions} for " \
        "#{distance_words(now - idle_since)} of the #{threshold.inspect} it needs.#{cooldown_clause}"
    when :latched
      "This quiet stretch has already fired. The next one starts when the fleet reaches its ceiling of " \
        "#{max_sessions} again, and can fire #{min_fire_interval.inspect} after the last fire at the earliest."
    when :cooling_down
      "Past the threshold and waiting out the #{min_fire_interval.inspect} cooldown — " \
        "#{distance_words(last_fired_at + min_fire_interval - now)} left."
    when :due
      "The fleet is holding #{sessions} and has been under its ceiling past the threshold: the event " \
        "fires at the next check, unless something is parked on an auth outage or the account pool is empty."
    end
  end

  private

  # Appended to the states whose own clock is not the binding one. Without it the
  # card answers "due in 5 minutes" while an unspent cooldown holds the fire for
  # another 40 — the threshold is the smaller number and the wrong one.
  def cooldown_clause
    return "" unless cooldown_pending?

    " The #{min_fire_interval.inspect} cooldown since the last fire has " \
      "#{distance_words(cooldown_ends_at - now)} left, and it is the later of the two."
  end

  def sessions
    "#{sessions_in_hand} #{"session".pluralize(sessions_in_hand)}"
  end

  def distance_words(seconds)
    ActionController::Base.helpers.distance_of_time_in_words(seconds.clamp(0, nil))
  end
end
