# frozen_string_literal: true

# How often GithubTriggerPollerJob polls, and every window that has to move with it.
#
# The poller's windows are written here in TIME, and each turns into a tick count for whatever
# interval is set. Counted in ticks they would stretch with the interval: once GitHub's webhook carries
# the triggers the poller becomes a slow backstop, and at 15 minutes a three-tick grace would be 45
# minutes and a five-tick page 75.
#
# The interval is `GITHUB_TRIGGER_POLL_INTERVAL_MINUTES`, read like the ingest mode (encrypted
# credentials, then ENV), a whole number of minutes from 1 to 60. Unset, blank or invalid reads as
# one minute — the cadence the cron entry runs at — and at one minute the windows are 3 misses, 5
# sweeps, a 1-hour streak TTL and a 15-minute liveness threshold.
#
# The cron entry still enqueues every minute. A longer interval is enforced by #due?, which lets a
# sweep through only once the previous one started at least an interval ago.
class GithubTriggerPollCadence
  SETTING_KEY = "GITHUB_TRIGGER_POLL_INTERVAL_MINUTES"
  DEFAULT_INTERVAL = 1.minute
  MAX_INTERVAL = 60.minutes

  # How long a seen `github_label` key must stay missing from the search before the poller accepts
  # the label as removed. GitHub's index is eventually consistent, so one empty answer is not proof.
  # Never fewer than MIN_REMOVAL_MISSES consecutive misses, whatever the interval: a single miss is
  # exactly the index blip the grace exists for, so at 15 minutes a removal registers on the second
  # miss in a row, 15 minutes after the first.
  REMOVAL_GRACE = 3.minutes
  MIN_REMOVAL_MISSES = 2

  # How long a degradation (incomplete search index, rate-limited sweeps) may run before it pages.
  # Never fewer than MIN_SWEEPS_BEFORE_ALERT sweeps, so one bad sweep at a slow cadence is still
  # read as a blip.
  DEGRADED_BEFORE_ALERT = 5.minutes
  MIN_SWEEPS_BEFORE_ALERT = 2

  # A degradation streak lives in the cache this long, and never fewer than STREAK_TTL_INTERVALS
  # intervals: a missed tick must not silently reset a streak.
  STREAK_TTL = 1.hour
  STREAK_TTL_INTERVALS = 4

  # TriggerPollerLivenessCheckJob pages when no sweep has succeeded for this long: two intervals
  # plus slack, never under a quarter-hour.
  LIVENESS_FLOOR = 15.minutes
  LIVENESS_SLACK = 5.minutes

  # Cron enqueues on the minute and a sweep starts some seconds later — more when the `pollers` queue
  # is busy — so two starts one interval apart can read as up to most of a minute under it. Anything
  # less than one cron period keeps a late start from costing the next sweep a whole extra tick.
  DUE_SLACK = 50.seconds

  LAST_SWEEP_KEY = "github_trigger_poller:last_sweep_started_at"

  def self.current
    new(interval: configured_interval)
  end

  def self.configured_interval
    raw = (SecretsLoader.get(SETTING_KEY).presence || ENV[SETTING_KEY].presence).to_s.strip
    return DEFAULT_INTERVAL if raw.empty?

    minutes = Integer(raw, 10)
    return minutes.minutes if minutes.minutes.between?(DEFAULT_INTERVAL, MAX_INTERVAL)

    warn_invalid(raw)
    DEFAULT_INTERVAL
  rescue ArgumentError, TypeError
    warn_invalid(raw)
    DEFAULT_INTERVAL
  end

  # Once per value per process: this is read on every tick.
  def self.warn_invalid(raw)
    @warned ||= Concurrent::Set.new
    return unless @warned.add?(raw)

    Rails.logger.warn("[GithubTriggerPollCadence] #{SETTING_KEY}=#{raw.inspect} is not a whole number of minutes " \
                      "from 1 to #{MAX_INTERVAL.in_minutes.to_i}; polling every minute")
  end

  attr_reader :interval

  def initialize(interval: DEFAULT_INTERVAL)
    @interval = interval
  end

  def interval_minutes
    (interval / 60).to_i
  end

  def default?
    interval == DEFAULT_INTERVAL
  end

  # Consecutive misses after which a seen label key is dropped. 3 at one minute.
  def removal_grace_misses
    [ MIN_REMOVAL_MISSES, ticks_in(REMOVAL_GRACE) ].max
  end

  # Consecutive degraded sweeps after which the poller pages. 5 at one minute.
  def sweeps_before_alert
    [ MIN_SWEEPS_BEFORE_ALERT, ticks_in(DEGRADED_BEFORE_ALERT) ].max
  end

  def streak_ttl
    [ STREAK_TTL, interval * STREAK_TTL_INTERVALS ].max
  end

  # 15 minutes at one minute and at five; 35 at fifteen.
  def liveness_threshold
    [ LIVENESS_FLOOR, (interval * 2) + LIVENESS_SLACK ].max
  end

  # Whether a sweep should run now. Always at the default interval, which is the cron's own
  # cadence. Otherwise only once the last sweep started at least an interval ago; a cache that
  # cannot be read answers yes, because polling too often costs budget and polling too seldom
  # costs triggers.
  def due?(now: Time.current)
    return true if default?

    last = Rails.cache.read(LAST_SWEEP_KEY)
    return true if last.nil?

    now - Time.zone.at(last.to_f) >= interval - DUE_SLACK
  rescue => e
    Rails.logger.warn("[GithubTriggerPollCadence] Could not read the last sweep time (#{e.message}); polling now")
    true
  end

  def record_sweep_started(now: Time.current)
    return if default?

    Rails.cache.write(LAST_SWEEP_KEY, now.to_f, expires_in: interval * 3)
  rescue => e
    Rails.logger.warn("[GithubTriggerPollCadence] Could not record the sweep start: #{e.message}")
  end

  private

  def ticks_in(duration)
    (duration.to_f / interval).ceil
  end
end
