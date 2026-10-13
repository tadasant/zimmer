# frozen_string_literal: true

# One reading of everything FleetIdleMonitor decides on, so the /inference card
# and `get_spot_policy` describe the same fleet in the same words rather than
# taking two readings a moment apart.
#
# Four states look identical from outside — "it has not fired" — and clear in
# four different ways: the fleet is over its ceiling, the stretch is inside the
# threshold, the cooldown is unspent, or the backlog has had nothing new since the
# last fire and the longer quiet interval is unspent. This names which one the monitor is in,
# and when the next fire is due.
#
# Read-only. It never advances a clock and never fires anything; the monitor owns
# both, and a page render must not be able to spawn a session.
class FleetTopUpStatus
  # Ordered the way `check!` reaches them, which is also the order they resolve
  # in: a fleet over its ceiling has not started a clock, a clock that has not
  # crossed the threshold has not reached the cooldown, and so on.
  STATES = %i[at_ceiling clock_not_started inside_threshold cooling_down backlog_quiet due].freeze

  attr_reader :setting, :running_sessions, :max_sessions, :threshold, :min_fire_interval,
    :quiet_backlog_interval, :idle_since, :last_fired_at, :now, :turns

  def self.current(setting: AppSetting.current, now: Time.current)
    new(setting: setting, turns: FleetIdleMonitor.running_turns, now: now)
  end

  def initialize(setting:, turns:, now: Time.current)
    @setting = setting
    @turns = turns
    @running_sessions = turns.on_a_worker
    @now = now
    @max_sessions = FleetIdleMonitor.max_sessions(setting)
    @threshold = FleetIdleMonitor.idle_threshold(setting)
    @min_fire_interval = FleetIdleMonitor.min_fire_interval(setting)
    @quiet_backlog_interval = FleetIdleMonitor.quiet_backlog_interval(setting)
    @idle_since = setting.fleet_idle_since
    @last_fired_at = setting.fleet_idle_event_fired_at
  end

  # Whether a worker is running few enough turns for the fleet to count as idle.
  # Only the first of the monitor's three questions — a fleet under its ceiling can still
  # be held off by an auth-outage park or an empty account pool, both of which
  # the rest of this page already reports in their own words.
  def under_ceiling?
    running_sessions < max_sessions
  end

  # How much room is left before the fleet stops counting as idle enough.
  def headroom
    [ max_sessions - running_sessions, 0 ].max
  end

  # The in-flight turns #running_sessions leaves out, reported beside it rather
  # than folded into it. Since #1040 a turn handed to a session sits in `waiting`
  # until a worker picks it up, so the queue is a different STATUS rather than a
  # share of `running` — but it is just as real and just as uncounted, and
  # RunningTurns is still the one place the split is computed. Reported because a
  # queue that is not in the ceiling is still
  # the answer to "why is nothing of mine moving".
  def awaiting_sessions = turns.awaiting_a_worker

  # The other rows outside the count: asleep on their own future wake with no
  # worker on them and nothing queued, so Zimmer will not start them before that
  # wake and no turn is coming for them in the meantime.
  def asleep_sessions = turns.asleep

  # How many agent turns this deployment can execute at once — the worker pool
  # behind the `agents` queue, and the hard ceiling on #running_sessions whatever
  # the policy number is set to. An operator reading a queue that never drains
  # needs this number next to the one they configured.
  def worker_slots = RunningTurns.worker_slots

  # Whether the configured ceiling is above that pool, and so out of the fleet's
  # reach: the count is turns on a worker, so it can never get there and the
  # fleet always reads as having room. The card says this out loud — a ceiling
  # that never binds looks like a working limit until you notice it has never
  # fired.
  def ceiling_out_of_reach? = RunningTurns.ceiling_out_of_reach?(max_sessions)

  # The ceiling actually in force: the smaller of what was configured and what
  # the pool can run.
  def effective_ceiling = RunningTurns.effective_ceiling(max_sessions)

  # The clock the threshold is measured against, or nil when no stretch is
  # running — which is what `fleet_idle_since` holds, EXCEPT in the window
  # between the fleet reaching its ceiling and the next observation of it. In
  # that window the stored value is a stretch that is already over, and the two
  # surfaces would otherwise print "under its ceiling since 3 hours ago" beside a
  # badge reading "at its work ceiling". Report what the next sweep will store
  # rather than what the last one did.
  def under_ceiling_since
    idle_since if under_ceiling?
  end

  def state
    return :at_ceiling unless under_ceiling?
    return :clock_not_started if idle_since.nil?
    return :inside_threshold if now - idle_since < threshold
    # The quiet interval is checked first: when it applies it always ends at or
    # after the cooldown, so it is the clock holding the fire for the whole of it.
    return :backlog_quiet if quiet_backlog_binding?
    return :cooling_down if last_fired_at.present? && now - last_fired_at < min_fire_interval

    :due
  end

  # Whether the quiet-backlog interval, rather than the cooldown, is what holds
  # the next fire: it is unspent, it ends after the cooldown, and the backlog has
  # had no news since the last fire.
  def quiet_backlog_binding?
    quiet_backlog_pending? && quiet_backlog_ends_at > cooldown_ends_at && !backlog_news?
  end

  # Whether the backlog has had anything to hand out since the last fire — the
  # monitor's own reading, asked once per status. True when nothing has fired
  # yet, since there is no last fire to compare against.
  def backlog_news?
    return true if last_fired_at.nil?
    return @backlog_news if defined?(@backlog_news)

    @backlog_news = FleetIdleMonitor.backlog_news_since?(last_fired_at)
  end

  # The earliest moment the event could fire, or nil when no clock is running
  # toward one — which happens only when the fleet is at or over its ceiling.
  #
  # Both clocks are consulted in every branch that has them. The threshold alone
  # is the wrong answer for the whole interval after a fire: the stretch runs
  # straight THROUGH the fire, since only the fleet reaching its ceiling ends one,
  # so `cooling_down` is the ORDINARY state for the rest of that hour and
  # answering "5 minutes" there would under-report by up to 55.
  #
  # An estimate by construction: the fleet can reach its ceiling at any moment
  # and put the idle clock back.
  def next_fire_at
    case state
    when :at_ceiling then nil
    when :due then now
    when :clock_not_started then [ now + threshold, binding_floor_ends_at ].compact.max
    else [ idle_since + threshold, binding_floor_ends_at ].compact.max
    end
  end

  # When the quiet-backlog interval since the last fire is spent, or nil when
  # nothing has fired yet.
  def quiet_backlog_ends_at
    last_fired_at && last_fired_at + quiet_backlog_interval
  end

  def quiet_backlog_pending?
    quiet_backlog_ends_at.present? && quiet_backlog_ends_at > now
  end

  # Whichever floor since the last fire actually holds the next one: the quiet
  # interval while the backlog has nothing new, otherwise the cooldown. The later
  # of the two either way, so a quiet interval set below the cooldown never
  # brings the answer forward.
  def binding_floor_ends_at
    return cooldown_ends_at if backlog_news?

    [ cooldown_ends_at, quiet_backlog_ends_at ].compact.max
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
    per_day_phrase(min_fire_interval)
  end

  # The same, for a backlog that has nothing new: the slower of the two floors.
  def quiet_cadence_phrase
    per_day_phrase([ min_fire_interval, quiet_backlog_interval ].max)
  end

  def sentence
    case state
    when :at_ceiling
      "The fleet has #{sessions} on a worker#{split_clause} — at or over its ceiling of #{max_sessions}, " \
        "so no top-up is due. The clock starts again when it drops below #{max_sessions}."
    when :clock_not_started
      "The fleet has #{sessions} on a worker#{split_clause}, under its ceiling of #{max_sessions}. The idle " \
        "clock starts at the next check, and the event is due #{threshold.inspect} after that.#{cooldown_clause(now + threshold)}"
    when :inside_threshold
      "The fleet has been under its ceiling of #{max_sessions} for " \
        "#{distance_words(now - idle_since)} of the #{threshold.inspect} it needs.#{cooldown_clause(idle_since + threshold)}"
    when :cooling_down
      "The fleet has been under its ceiling of #{max_sessions} for #{distance_words(now - idle_since)}, " \
        "past the #{threshold.inspect} it needs — now waiting out the #{min_fire_interval.inspect} cooldown " \
        "since the last fire, #{distance_words(cooldown_ends_at - now)} left."
    when :backlog_quiet
      "The fleet has been under its ceiling of #{max_sessions} for #{distance_words(now - idle_since)}, " \
        "but the work backlog has had nothing new since the last fire — nothing queued since, and " \
        "nothing started from what is left — so the next top-up waits out the " \
        "#{quiet_backlog_interval.inspect} quiet interval, #{distance_words(quiet_backlog_ends_at - now)} " \
        "left. A new item on the backlog brings it forward to the next check."
    when :due
      "The fleet has #{sessions} on a worker#{split_clause} and has been under its ceiling of " \
        "#{max_sessions} for #{distance_words(now - idle_since)}, past the #{threshold.inspect} it needs: " \
        "the event fires at the next check, unless something is parked on an auth outage or the account " \
        "pool is empty."
    end
  end

  private

  def per_day_phrase(interval)
    fires = (1.day / interval).floor
    return "at most once every #{ActiveSupport::Duration.build(interval.to_i).inspect}" if fires < 1

    "at most #{fires} #{"top-up".pluralize(fires)} a day"
  end

  # Appended to the states whose own clock is not the binding one. Without it the
  # card answers "due in 5 minutes" while an unspent cooldown holds the fire for
  # another 40 — the threshold is the smaller number and the wrong one.
  #
  # The quiet-backlog interval is the same kind of floor and outranks the
  # cooldown whenever it applies, so it is the one named then.
  def cooldown_clause(threshold_ends_at)
    if quiet_backlog_binding? && quiet_backlog_ends_at > threshold_ends_at
      return " The backlog has had nothing new since the last fire, so the #{quiet_backlog_interval.inspect} " \
        "quiet interval has #{distance_words(quiet_backlog_ends_at - now)} left, and it is the later of the " \
        "clocks unless new work reaches the backlog first."
    end
    return "" unless cooldown_pending?

    " The #{min_fire_interval.inspect} cooldown since the last fire has " \
      "#{distance_words(cooldown_ends_at - now)} left, and it is the later of the two."
  end

  def sessions
    "#{running_sessions} #{"session".pluralize(running_sessions)}"
  end

  # What the number leaves out, and only when there is something to leave out —
  # on a fleet with an empty queue and nobody asleep it is the whole story on its
  # own. Where it is not, these are the `running` rows an operator can see and
  # the ceiling deliberately does not count.
  def split_clause
    parts = []
    if awaiting_sessions.positive?
      parts << "#{awaiting_sessions} more waiting for one of the #{worker_slots} worker slots"
    end
    parts << "#{asleep_sessions} asleep on a wake" if asleep_sessions.positive?
    return "" if parts.empty?

    " (#{parts.join(', ')} — not counted)"
  end

  def distance_words(seconds)
    ActionController::Base.helpers.distance_of_time_in_words(seconds.clamp(0, nil))
  end
end
