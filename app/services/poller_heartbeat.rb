# frozen_string_literal: true

# The liveness heartbeat every trigger poller stamps and TriggerPollerLivenessCheckJob reads.
#
# A poller has two ways of going silent, and its per-condition rescue reports neither. It
# can stop running at all — a hung subprocess holding the singleton slot, a downed
# `pollers` worker, a cron manager that stopped enqueueing — so no code runs to raise. Or
# it can keep running and poll nothing: a preflight that fails every tick, an upstream that
# refuses every request, a sweep whose every unit is thrown away before its cursor moves.
# In both, `perform` either never runs or returns normally, and the queue looks flat.
#
# The heartbeat is the one fact that distinguishes a poller that is polling from one that
# is not: a Rails.cache (Redis) key holding the time of the last sweep that GENUINELY
# polled something. Each poller decides what "genuinely" means for its own feed and stamps
# only then — see GithubTriggerPollerJob and SlackTriggerPollerJob, where the placement of
# the stamp is the whole point and each one explains its bar. A stamp that fires because
# "the sweep ran" is green through exactly the outages it exists to report.
#
# This module is the ONE implementation of the plumbing: the key, the TTL, the format, and
# the tolerant read. It holds no policy — thresholds, seeding and paging belong to the
# check that reads it.
module PollerHeartbeat
  # The pollers that heartbeat, each with its own key. A key rather than a prefix plus
  # interpolation, so a typo is a KeyError at the call site rather than a heartbeat nobody
  # reads. The GitHub key predates this module and keeps its name so a deploy does not
  # discard the heartbeat the running poller has already stamped.
  CACHE_KEYS = {
    github: "github_trigger_poller:last_successful_poll_at",
    slack: "slack_trigger_poller:last_successful_poll_at"
  }.freeze

  # Generous, so the key survives a multi-hour poller outage holding its LAST-success
  # timestamp — that stale value is exactly what the liveness check needs to read to know
  # polling has stopped. If the key instead expired mid-outage the check would see an
  # absence it cannot date and stay quiet. Well beyond any outage we expect to page on; a
  # healthy poller rewrites it every minute.
  TTL = 7.days

  module_function

  def cache_key(poller)
    CACHE_KEYS.fetch(poller)
  end

  # Record that +poller+ just completed a sweep that genuinely polled its feed.
  #
  # Rescued rather than raised: a cache write failure must never take down a poll that
  # otherwise succeeded. The check tolerates a missing heartbeat (it seeds and skips) far
  # better than the poll tolerates an exception here.
  def stamp(poller)
    # Resolved outside the rescue: an unknown poller is a bug at the call site, not a
    # cache failure to be logged and forgotten.
    key = cache_key(poller)

    begin
      Rails.cache.write(key, Time.current.utc.iso8601, expires_in: TTL)
      true
    rescue => e
      Rails.logger.warn "[PollerHeartbeat] Failed to record the #{poller} poll heartbeat: #{e.message}"
      false
    end
  end

  # The raw cached value — for the check's log line, which reports what it could not read.
  def raw(poller)
    Rails.cache.read(cache_key(poller))
  end

  # The heartbeat as a Time, or nil when it is absent or unreadable.
  #
  # We only ever write iso8601, so an unparseable value is belt-and-braces (a hand-edited
  # or half-written key) rather than an expected path — but it must degrade to "no
  # baseline" instead of crashing the check on every run. Time.iso8601 signals bad input
  # with ArgumentError (Date::Error, which it may raise instead, subclasses it) and a
  # non-String with TypeError.
  def last_at(poller)
    value = raw(poller)
    return nil if value.blank?

    Time.iso8601(value)
  rescue ArgumentError, TypeError
    nil
  end
end
