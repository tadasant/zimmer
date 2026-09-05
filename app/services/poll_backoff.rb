# Activity-based exponential backoff for per-session GitHub polling.
#
# Github::PrPollPass iterates every active session with a tracked PR on every cron
# tick. At ~50 sessions x multiple PRs that exhausts GitHub's authenticated rate
# limit (5000/hr).
#
# This module slows down per-session polling based on how recently the user has
# touched the session. It does NOT change cron cadence — it short-circuits inside
# the pass when the session hasn't earned another poll yet.
#
# There were three iterations here once, one per poller job, each with its own key
# and its own stamp write. The pass fused them (#711), and the keys that survive
# are the pass's own plus the two evaluators that keep a slower floor inside it —
# all stamped in one write, because `record_poll!` takes a list.
#
# Backoff curve (time since last user activity -> minimum interval between polls):
#
#   < 30 min   -> always poll (every cron tick)
#   30 min – 2 hr -> 2x the job's base cadence
#   2 hr – 8 hr   -> max(5 min, base)
#   8 hr – 24 hr  -> max(30 min, base)
#   > 24 hr       -> 24 hr (floor specified by the user request)
#
# The curve measures *engagement*, which is the wrong question for a session
# that is idle because it is waiting on one specific external event. A caller
# that knows a session is in that state passes `max_interval` to cap how far the
# curve may stretch it — see Github::PrPollPass, where a session holding an
# unresolved PR is capped at the 8–24 hr bucket's own floor rather than decaying
# to one poll a day (#494).
#
# Per-key last-poll timestamps are stored in
# `session.custom_metadata['poller_last_polled_at'][job_key]` as ISO8601 strings.
module PollBackoff
  module_function

  # Decide whether this session is due for another poll by `job_key`.
  #
  # @param session [Session]
  # @param job_key [String] stable identifier per poller job
  # @param base_interval [Integer] the job's normal cadence in seconds
  # @param max_interval [Integer, nil] ceiling in seconds on the backed-off
  #   interval, for a session the caller knows is awaiting a specific event
  # @param min_interval [Integer, nil] floor in seconds on the interval, for a
  #   caller whose cadence is no longer supplied by cron — see #poll_interval
  # @return [Boolean] true if the job should poll this session now
  def should_poll?(session, job_key:, base_interval:, max_interval: nil, min_interval: nil)
    interval = poll_interval(
      session, base_interval: base_interval, max_interval: max_interval, min_interval: min_interval
    )
    return true if interval <= 0

    last_polled = parse_last_polled_at(session, job_key)
    return true if last_polled.nil?

    Time.current - last_polled >= interval
  end

  # Stamp this session as having been polled by `job_key` just now.
  # Stored under custom_metadata so it doesn't conflict with the existing
  # session metadata used for retry/recovery state.
  #
  # `job_key` takes an array as readily as a string, and that is the point: one pass
  # that ran several gated evaluators stamps all of their keys in ONE reload and ONE
  # UPDATE. Three separate stamp writes per session per tick was the database half of
  # what #711 was about.
  #
  # @param job_key [String, Array<String>] the key(s) to stamp
  def record_poll!(session, job_key:)
    session.reload if session.persisted?
    last_polled = (session.custom_metadata&.dig("poller_last_polled_at") || {}).dup
    now = Time.current.iso8601
    Array(job_key).each { |key| last_polled[key] = now }
    session.merge_custom_metadata!("poller_last_polled_at" => last_polled)
  end

  # The minimum interval (seconds) between polls for this session, based on
  # how stale the user's last interaction is.
  #
  # `max_interval` caps the result. It never raises the interval — a base
  # cadence longer than the cap still wins, because the cap is a promise about
  # the worst case, not a demand to poll faster than the job runs.
  #
  # `min_interval` floors it, and it exists because the curve returns 0 for a
  # recently-active session: "poll on every tick" was a safe answer while each
  # poller had its own cron entry to supply the cadence, and it stopped being one
  # when they were fused into a single 30-second pass. An evaluator that must not
  # run faster than its old cron says so here — Github::PrPollPass floors the merge
  # conflict evaluator at the two minutes its debounce was tuned against.
  def poll_interval(session, base_interval:, max_interval: nil, min_interval: nil)
    activity_age = Time.current - session.last_user_activity_at

    interval =
      if activity_age < 30.minutes
        0
      elsif activity_age < 2.hours
        base_interval * 2
      elsif activity_age < 8.hours
        [ 5.minutes.to_i, base_interval ].max
      elsif activity_age < 24.hours
        [ 30.minutes.to_i, base_interval ].max
      else
        24.hours.to_i
      end

    interval = [ interval, [ max_interval, base_interval ].max ].min unless max_interval.nil?
    interval = [ interval, min_interval ].max unless min_interval.nil?

    interval
  end

  def parse_last_polled_at(session, job_key)
    raw = session.custom_metadata&.dig("poller_last_polled_at", job_key)
    return nil if raw.blank?

    Time.parse(raw.to_s)
  rescue ArgumentError
    nil
  end
  private_class_method :parse_last_polled_at
end
