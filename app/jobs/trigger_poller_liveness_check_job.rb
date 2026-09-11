# frozen_string_literal: true

# Pages when a trigger poller has silently stopped polling.
#
# Each poller's only failure signal of its own is its per-condition rescue, which alerts
# when a poll RAISES. That misses the whole class of failures where nothing raises at all:
#   - a subprocess or HTTP call hangs against a degraded upstream (bounded now, but a bound
#     is defence, not a guarantee);
#   - the `pollers` GoodJob worker is down, so no tick runs to raise anything;
#   - the singleton concurrency slot is held, so every enqueue is a silent no-op;
#   - the poller runs every minute and polls nothing — a preflight failing every tick, an
#     upstream refusing every request, a sweep whose every unit is thrown away.
# In each case the poller stops advancing state — the merge and issue gates quietly go
# dark, Slack triggers stop firing — with not one line in #alerts. That is exactly how the
# `ready to merge` gate stalled for ~50 minutes unnoticed, and it is the gap the Slack
# poller had no cover for at all until it started heartbeating (#525).
#
# Each poller stamps PollerHeartbeat on every sweep that genuinely polled something; this
# job reads both heartbeats and pages #alerts (through the obs pipeline) when one goes
# stale — i.e. no poll of that feed has succeeded within its threshold. A heartbeat that
# keeps advancing means the poller is alive even if individual conditions are erroring
# (those page on their own), so this fires only on a genuine, total stall. The other half
# of the monitor — one condition that has quietly stopped while its siblings keep the
# heartbeat fresh — is the per-feed freshness check: GithubTriggerHealthCheckJob and
# SlackTriggerHealthCheckJob.
#
# Queue placement — `default`, deliberately NOT `pollers`. This monitor watches the
# `pollers`-queue pollers, and a monitor must not run on the queue it watches or the very
# outage it exists to report (a wedged/starved `pollers` worker) would starve it into
# silence too. SystemHealthMonitorJob documents the same rule inverted: it watches
# `default`, so it runs on `pollers`.
class TriggerPollerLivenessCheckJob < ApplicationJob
  queue_as :default

  # Singleton: at most one check unfinished at a time, matching the other periodic
  # monitors. A check is cheap; this just prevents overlapping cron ticks from stacking.
  include SingletonSweep

  # What the check needs to know about one poller. Everything that differs between the
  # two feeds lives here; the check itself is the same for both.
  #
  #   key:        the PollerHeartbeat key.
  #   threshold:  how long the poller may go without a genuine poll before we page.
  #   watched:    whether there is anything for the poller to poll. With nothing enabled the
  #               poller has nothing to do, its heartbeat says nothing, and there is no stall
  #               to report.
  #   seedable:   whether a host with NO heartbeat should be given a baseline. A host that
  #               cannot poll (no credential) legitimately never heartbeats and must not be
  #               seeded, or the seed would age into a page for a poller that was never
  #               supposed to run. Consulted ONLY on the no-heartbeat path — see #check.
  #   title:      the alert message. Stable across runs: GlitchTip groups by message and
  #               notifies once per issue, and Grafana groups by alertname, so an outage that
  #               lasts hours pages once per dedup window rather than once per run. The age
  #               rides in the details, which do not group.
  #   details:    the page's body, given the stall's age in minutes and the last heartbeat.
  Poller = Data.define(:key, :threshold, :watched, :seedable, :title, :details)

  POLLERS = [
    Poller.new(
      key: :github,
      # The poller runs every minute, so this is ~15 consecutive missed/failed ticks — far
      # beyond any transient blip or a slow multi-page search, yet tight enough to catch a
      # real freeze within the quarter-hour rather than the ~50 minutes the incident ran.
      threshold: 15.minutes,
      watched: -> { TriggerCondition.github.joins(:trigger).where(triggers: { status: "enabled" }).exists? },
      # `configured?` shells out to `gh auth status` — a live API call that a GitHub outage
      # makes fail. It is consulted here and nowhere else, and the placement is the whole
      # point; see #check.
      seedable: -> { GithubSearchService.configured? },
      title: "GitHub trigger polling stalled",
      details: lambda do |minutes, last_at|
        "No GitHub trigger poll has completed successfully in ~#{minutes} minutes " \
          "(last success #{last_at}). Label and issue triggers — including the `ready to merge` " \
          "merge gate — are not firing. Likely causes: the `pollers` GoodJob worker is down, a " \
          "`gh` call is hung against a degraded GitHub API, or GitHub is unreachable. Check the " \
          "GoodJob dashboard (/jobs) and githubstatus.com."
      end
    ),
    Poller.new(
      key: :slack,
      # Wider than GitHub's, on purpose. A Slack outage the poller can see is already
      # paged by its own deferral chain: five deferrals of exponential backoff hold the
      # singleton slot for roughly a quarter of an hour, then SlackTriggerPollerJob reports
      # "deferred repeatedly" and the next cron tick starts a fresh chain. None of those
      # sweeps stamps, so a threshold inside that window would page a second time for an
      # outage the poller is already reporting. Past it, a stale heartbeat means the chain
      # itself is not running — the wedge, the dead worker — or that Slack has been refusing
      # every sweep for two chains in a row, which is the backstop this exists to be.
      threshold: 30.minutes,
      watched: -> { TriggerCondition.slack.joins(:trigger).where(triggers: { status: "enabled" }).exists? },
      # Offline — a token-presence check — so unlike `gh auth status` it cannot be failed by
      # an outage. It still only decides seeding: a host with no Slack token never polls
      # and must not be given a baseline to age.
      seedable: -> { SlackService.configured? },
      title: "Slack trigger polling stalled",
      details: lambda do |minutes, last_at|
        "No Slack trigger poll has completed cleanly in ~#{minutes} minutes (last success " \
          "#{last_at}). Slack triggers — @mentions, DMs, #alerts and the passive listeners — are " \
          "not firing. Likely causes: the `pollers` GoodJob worker is down, a poll is wedged " \
          "holding the singleton slot, or Slack has been refusing every sweep for longer than " \
          "the poller's own deferral chain. Check the GoodJob dashboard (/jobs) and " \
          "status.slack.com."
      end
    )
  ].freeze

  def perform
    POLLERS.each { |poller| check(poller) }
  end

  private

  def check(poller)
    return unless poller.watched.call

    last_at = PollerHeartbeat.last_at(poller.key)

    if last_at.nil?
      # No usable baseline: a fresh boot, a cache flush, or a gap longer than the
      # heartbeat's TTL. There is no absence we can date, and paging on one would be a
      # false alarm, so seed instead — the NEXT check then measures against a real point
      # in time. A genuine ongoing stall is still caught: the poller isn't rewriting the
      # key, so this seed itself ages past the threshold and the next check pages.
      #
      # The credential is checked HERE and nowhere else. A host with no credential
      # (staging, for GitHub) legitimately never polls and so never heartbeats, and must
      # not be seeded or paged about. But testing the credential up front would hand this
      # job the same silence it exists to break: during an upstream incident the preflight
      # fails, the check returns, and the stall it was watching for goes unreported. Once
      # a heartbeat EXISTS, this host has demonstrably polled, so a stale one is an
      # incident whatever the preflight now says — including the case where polling
      # stopped BECAUSE the credential was revoked.
      return unless poller.seedable.call

      raw = PollerHeartbeat.raw(poller.key)
      PollerHeartbeat.stamp(poller.key)
      Rails.logger.info "[TriggerPollerLivenessCheckJob] No usable #{poller.key} poll heartbeat " \
                        "(#{raw.inspect}); seeded a baseline, not alerting."
      return
    end

    age = Time.current - last_at
    return if age < poller.threshold

    minutes = (age / 60).round
    # .error, not .warn: this line IS the page — the ERROR record is what reaches
    # #alerts, and the stall does not self-resolve.
    Rails.logger.error "[TriggerPollerLivenessCheckJob] No successful #{poller.key} trigger poll " \
                       "in ~#{minutes}m (last success #{last_at})"
    ErrorReporter.report_message(
      poller.title,
      level: :error,
      context: {
        source: "TriggerPollerLivenessCheckJob",
        poller: poller.key.to_s,
        details: poller.details.call(minutes, last_at)
      }
    )
  end
end
