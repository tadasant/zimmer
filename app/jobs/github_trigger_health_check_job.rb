# frozen_string_literal: true

# Proactively detects that GitHub trigger polling has silently stopped.
#
# GithubTriggerPollerJob's only failure signal is its per-condition rescue, which
# alerts when a search RAISES. That misses the whole class of failures where nothing
# raises at all:
#   - the `gh` subprocess hangs against a degraded GitHub API (now bounded by
#     GithubSearchService::REQUEST_TIMEOUT, but a bound is defence, not a guarantee);
#   - the `pollers` GoodJob worker is down, so no tick runs to raise anything;
#   - the singleton concurrency slot is held, so every enqueue is a silent no-op.
# In each case the poller stops advancing state — the merge/issue gates quietly go
# dark — with not one line in #eng-alerts. That is exactly how the `ready to merge`
# gate stalled for ~50 minutes unnoticed.
#
# This job closes that gap, mirroring SlackTriggerHealthCheckJob for the Slack poller.
# The poller stamps GithubTriggerPollerJob::HEARTBEAT_CACHE_KEY every time a sweep polls
# at least one condition successfully; this check reads that heartbeat and pages
# #eng-alerts (via AlertService) when it goes stale — i.e. no GitHub poll has succeeded
# in STALE_THRESHOLD. A heartbeat that keeps advancing means the poller is alive even
# if individual conditions are erroring (those page on their own), so this fires only on
# a genuine, total stall.
#
# Queue placement — `default`, deliberately NOT `pollers`. This monitor watches the
# `pollers`-queue poller, and a monitor must not run on the queue it watches or the very
# outage it exists to report (a wedged/starved `pollers` worker) would starve it into
# silence too. SystemHealthMonitorJob documents the same rule inverted: it watches
# `default`, so it runs on `pollers`. SlackTriggerHealthCheckJob is on `default` for the
# same reason.
class GithubTriggerHealthCheckJob < ApplicationJob
  queue_as :default

  # Singleton: at most one check unfinished at a time, matching the other periodic
  # monitors. A check is cheap; this just prevents overlapping cron ticks from stacking.
  good_job_control_concurrency_with(
    key: -> { "github_trigger_health_check" },
    total_limit: 1
  )

  # How long the poller may go without a single successful poll before we page. The
  # poller runs every minute, so this is ~15 consecutive missed/failed ticks — far
  # beyond any transient blip or a slow multi-page search, yet tight enough to catch a
  # real freeze within the quarter-hour rather than the ~50 minutes the incident ran.
  STALE_THRESHOLD = 15.minutes

  # Stable dedup key: one page per AlertService::DEDUP_WINDOW (1h) for as long as the
  # stall persists, rather than a fresh page every run.
  ALERT_DEDUP_KEY = "github_trigger_poller_stalled"

  def perform
    # Mirror the poller's own guards. With no `gh` credential the poller can't run at
    # all (e.g. staging), so a missing/stale heartbeat there is expected, not an
    # incident. With no enabled GitHub triggers the poller returns early every tick and
    # never writes a heartbeat, which must likewise not read as a stall.
    return unless GithubSearchService.configured?
    return unless enabled_github_conditions?

    raw = Rails.cache.read(GithubTriggerPollerJob::HEARTBEAT_CACHE_KEY)
    last_at = parse_heartbeat(raw)

    if last_at.nil?
      # No usable baseline: a fresh boot, a cache flush, or a gap longer than the
      # heartbeat's TTL. There is no absence we can date, and paging on one would be a
      # false alarm, so seed instead — the NEXT check then measures against a real point
      # in time. A genuine ongoing stall is still caught: the poller isn't rewriting the
      # key, so this seed itself ages past the threshold and the next check pages.
      seed_heartbeat
      Rails.logger.info "[GithubTriggerHealthCheckJob] No usable poll heartbeat (#{raw.inspect}); " \
                        "seeded a baseline, not alerting."
      return
    end

    age = Time.current - last_at
    return if age < STALE_THRESHOLD

    minutes = (age / 60).round
    Rails.logger.warn "[GithubTriggerHealthCheckJob] No successful GitHub trigger poll in ~#{minutes}m " \
                      "(last success #{last_at}); alerting #eng-alerts."
    AlertService.raise_alert(
      "GitHub trigger polling stalled",
      details: "No GitHub trigger poll has completed successfully in ~#{minutes} minutes " \
               "(last success #{last_at}). Label and issue triggers — including the `ready to merge` " \
               "merge gate — are not firing. Likely causes: the `pollers` GoodJob worker is down, a " \
               "`gh` call is hung against a degraded GitHub API, or GitHub is unreachable. Check the " \
               "GoodJob dashboard (/jobs) and githubstatus.com.",
      source: "GithubTriggerHealthCheckJob",
      dedup_key: ALERT_DEDUP_KEY
    )
  end

  private

  # The heartbeat as a Time, or nil when it is absent or unreadable. We only ever write
  # iso8601, so an unparseable value is belt-and-braces (a hand-edited or half-written
  # key) rather than an expected path — but it must degrade to "no baseline" instead of
  # crashing the check on every run. Time.iso8601 signals bad input with ArgumentError
  # (Date::Error, which it may raise instead, subclasses it).
  def parse_heartbeat(raw)
    return nil if raw.blank?

    Time.iso8601(raw)
  rescue ArgumentError
    nil
  end

  def seed_heartbeat
    Rails.cache.write(
      GithubTriggerPollerJob::HEARTBEAT_CACHE_KEY,
      Time.current.utc.iso8601,
      expires_in: GithubTriggerPollerJob::HEARTBEAT_TTL
    )
  end

  def enabled_github_conditions?
    TriggerCondition.github
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .exists?
  end
end
