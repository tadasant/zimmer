# frozen_string_literal: true

# Proactively detects a GitHub trigger condition that has silently stopped keeping up.
#
# TriggerPollerLivenessCheckJob answers "is the poller polling at all?" from a heartbeat
# the poller stamps once per sweep. That heartbeat is stamped when ANY condition comes back
# clean, so it says nothing about one condition on its own: a condition that is polled every
# minute and never advances — its search answered, its state never written, its items never
# fired — keeps looking healthy for as long as its siblings keep the heartbeat fresh. This
# is the per-condition half of the monitor, the GitHub counterpart to
# SlackTriggerHealthCheckJob (#525).
#
# Once an hour, for each enabled condition, it asks GitHub the same question the poller
# asks — the poller's own query, through GithubTriggerSearch, so a difference between two
# queries can never read as a stall — and compares the answer against what the poller has
# recorded:
#
#   - a `github_issue` condition keeps a `created_at` cursor. The probe is that query with
#     no time bound, newest first: if the newest issue that the poller WOULD fire on is
#     newer than the cursor and old enough that the once-a-minute poller should long since
#     have advanced past it, the condition is stalled.
#   - a `github_label` condition keeps a seen-set. The probe is that query narrowed to
#     items not updated within the threshold: every one of them has carried its label for
#     at least that long (a label event moves `updated_at`, so `updated_at` bounds when
#     the label arrived), and any of them the seen-set does not hold is an item the poller
#     has been shown on every tick for hours and never recorded.
#
# What it can and cannot see, honestly. It catches the poller running against this
# condition and not landing state — the case the heartbeat masks — and it does so from
# GitHub's answer alone, with no dependence on the streak counters the poller keeps in the
# cache. It cannot catch a query that matches nothing: a renamed label, a repo the token
# lost access to, a scope edited into emptiness. Those return nothing to the poller and
# nothing to this probe alike, and a condition with no matching items is indistinguishable
# from a quiet one. Nor can it see a stalled labelled item that is still active — see
# #check_label_condition. Both gaps miss a stall; neither invents one.
#
# Two ways a trigger legitimately holds an item unfired are excluded before any search is
# spent: a trigger inside a burst it has already noticed, and a `skip_if_pending_session`
# trigger whose pending session is still carrying the intent. Both leave the item unrecorded
# ON PURPOSE so it fires for real later, and paging on them would report the design.
#
# Queue placement — `default`, deliberately NOT `pollers`: a monitor must not run on the
# queue it watches, or the outage it exists to report would starve it into silence too.
class GithubTriggerHealthCheckJob < ApplicationJob
  queue_as :default
  include SingletonSweep
  include GithubTriggerSearch

  # How far behind GitHub a condition may fall before its feed is read as stalled. Matches
  # SlackTriggerHealthCheckJob, and generous on purpose: this check is new to conditions
  # that may have been quietly dead for a while, and the poller has its own legitimate
  # delays — a burst window, a session-creation failure retried tick after tick with its
  # own ERROR — that a tighter bound would page for twice.
  STALE_THRESHOLD = 3.hours

  # How many of the newest issues a `github_issue` probe asks for. One would do for the
  # common case, but the newest issue can be one the poller correctly refuses — opened in
  # a repo before that repo joined the scope, or already fired at the cursor's exact
  # second — and a probe that stopped there would miss a stalled issue just behind it.
  # Still one request: a page of this size rather than a page of a hundred.
  NEWEST_ISSUES_PROBED = 10

  # How many stalled keys the page lists by name; the count is always the true one.
  MAX_ALERTED_KEYS = 25

  def perform
    # Unlike the liveness check, this one MAY guard on the credential up front, and does:
    # a host that cannot authenticate (staging) has no poller to keep up with, and during
    # an outage that fails the preflight the poller is not polling either — a stall the
    # liveness check pages on within minutes, and a probe skipped this hour loses nothing.
    return unless GithubSearchService.configured?

    TriggerCondition.github
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .includes(:trigger)
      .find_each do |condition|
      check_condition(condition)
    rescue GithubSearchService::RateLimitedError => e
      # The limit belongs to the credential, not to this condition, and every condition
      # left would spend a request to be told the same thing — on the one failure extra
      # requests make worse. Stop; the next hourly run is the retry.
      Rails.logger.info "[GithubTriggerHealthCheckJob] GitHub rate-limited the search API while " \
                        "checking condition #{condition.id}; skipping the rest of this run: #{e.message}"
      break
    rescue => e
      # A search failure checking one condition shouldn't abort the sweep or masquerade
      # as a stalled feed. Log at INFO — this self-resolves on the next hourly run, and a
      # search that is failing outright is already paged by the poller — and move on.
      Rails.logger.info "[GithubTriggerHealthCheckJob] Could not check condition #{condition.id}: #{e.message}"
    end
  end

  private

  def check_condition(condition)
    trigger = condition.trigger

    if trigger.bursting?
      Rails.logger.info "[GithubTriggerHealthCheckJob] Trigger #{trigger.id} is inside a burst; " \
                        "its unfired items are being held on purpose, so condition #{condition.id} is not probed"
      return
    end

    if trigger.skip_if_pending_session? && (pending = trigger.pending_intent_session)
      Rails.logger.info "[GithubTriggerHealthCheckJob] Trigger #{trigger.id} is skipping fires while " \
                        "session #{pending.id} is pending; condition #{condition.id} is not probed"
      return
    end

    case condition.condition_type
    when "github_label" then check_label_condition(condition)
    when "github_issue" then check_issue_condition(condition)
    end
  end

  # ── github_label ────────────────────────────────────────────────────────────

  def check_label_condition(condition)
    # Never polled: there is no seen-set to have fallen behind. Retargeted: the next tick
    # throws the seen-set away and re-baselines, so nothing in it means anything yet.
    return unless condition.github_baselined?
    return if condition.github_baseline_retargeted?

    # Only items whose LAST change is older than the threshold. A label event moves
    # `updated_at`, so every item this returns has carried its label — whichever of ours
    # it carries — for at least STALE_THRESHOLD, and the poller has been shown it on every
    # tick in between. Bounding the query this way also bounds the cost: the items that
    # can possibly be stalled, rather than the whole labelled set.
    #
    # The price is a blind spot, and it fails quiet: `updated_at` moves on ANY activity — a
    # comment, a push, another label — so a stalled item that is still being worked on is
    # excluded until it goes quiet for STALE_THRESHOLD. Seen-set membership alone could
    # not tell a stall from a label added a minute ago, so the bound is the trade.
    cutoff = (Time.current - STALE_THRESHOLD).utc.iso8601
    query = "#{label_query(condition)} updated:<=#{cutoff}"
    items = GithubSearchService.search_issues(query, sort: "created", order: "asc")

    # Keyed exactly as the poller keys its seen-set — configured casing, one key per
    # (item, watched label) — so the comparison is like against like.
    watched = condition.github_labels.index_by { |label| label.downcase }
    current_keys = items.flat_map do |item|
      labels_for(item).filter_map do |label|
        configured = watched[label.downcase]
        "#{item_key(item)}:#{configured}" if configured
      end
    end

    stalled = (current_keys.to_set - condition.github_seen_items.to_set).to_a.sort
    return if stalled.empty?

    report_stall(
      condition,
      "#{stalled.size} item(s) have carried a watched label for more than " \
      "#{(STALE_THRESHOLD / 3600).round}h and are not in the poller's seen-set: " \
      "#{listed(stalled)}. The poller is shown them on every tick and has recorded none of " \
      "them, so this condition is not landing state — its trigger is not firing for them."
    )
  end

  # ── github_issue ────────────────────────────────────────────────────────────

  def check_issue_condition(condition)
    cursor = condition.github_last_issue_at
    # Never polled: the first tick baselines the cursor, and there is nothing to fall
    # behind on until it has.
    return if cursor.blank?

    items = GithubSearchService.search_issues(
      issue_query(condition), sort: "created", order: "desc", limit: NEWEST_ISSUES_PROBED
    )

    # The newest issue the poller WOULD fire on. The poller refuses an issue that predates
    # its repo's baseline (history, not an event) and one whose key it has already fired,
    # so the probe refuses the same ones, or a refusal would read as a stall.
    baselines = condition.github_issue_repo_baselines
    already_fired = condition.github_seen_issue_keys.to_set
    newest = items.find do |item|
      !predates_repo_baseline?(item, baselines) && !already_fired.include?(item_key(item))
    end
    return if newest.nil?

    # The cursor is the created_at of the newest issue fired, in the same iso8601 the
    # search returns, so lexical and chronological order agree. Caught up → healthy.
    created_at = newest["created_at"].to_s
    return if created_at <= cursor.to_s

    lag = Time.current - Time.iso8601(created_at)
    return if lag < STALE_THRESHOLD

    report_stall(
      condition,
      "GitHub's newest matching issue (#{item_key(newest)}, opened #{created_at}, " \
      "~#{(lag / 3600.0).round(1)}h ago) is newer than the last one the poller fired on " \
      "(cursor #{cursor}). The once-a-minute poller should have advanced past it long ago, so " \
      "this condition is not landing state — its trigger is not firing."
    )
  end

  # ── Reporting ───────────────────────────────────────────────────────────────

  def report_stall(condition, what)
    details = "Condition #{condition.id} (#{condition.condition_type}) on trigger " \
              "'#{condition.trigger&.name}' (ID: #{condition.trigger_id}) watching " \
              "#{condition.github_repos.join(', ')} has fallen behind. #{what} Investigate " \
              "before dependent automation goes dark: the poller's own per-condition alerts say " \
              "whether its searches are failing; if they are quiet, the search is answering and " \
              "the state write or the fire is what is not landing."

    # .error, and this line is the load-bearing half: a stalled feed is a silence, so
    # nothing else here says anything. The ERROR record is what pages (any non-staging
    # Zimmer ERROR trips the Grafana rule, and it re-pages while the condition lasts); the
    # GlitchTip event below carries the detail. The message is stable so an ongoing stall
    # is one issue, not one per run.
    Rails.logger.error "[GithubTriggerHealthCheckJob] GitHub trigger feed stalled: #{details}"
    ErrorReporter.report_message(
      "GitHub trigger feed stalled",
      level: :error,
      context: {
        source: "GithubTriggerHealthCheckJob",
        details: details,
        condition_id: condition.id,
        trigger_id: condition.trigger_id
      }
    )
  end

  def listed(keys)
    return keys.join(", ") if keys.size <= MAX_ALERTED_KEYS

    "#{keys.first(MAX_ALERTED_KEYS).join(', ')} (+#{keys.size - MAX_ALERTED_KEYS} more)"
  end
end
