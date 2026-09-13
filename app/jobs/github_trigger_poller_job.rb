# frozen_string_literal: true

# Polls GitHub for `github_label` and `github_issue` trigger conditions, creating a
# session from the trigger's template when a watched repo produces a matching event.
#
# ## Turning polled STATE into an EVENT
#
# "A label was added" is an event, but a poll can only ever observe state: the label
# is *currently* on the item. A timestamp cursor cannot bridge that gap — an item's
# updated_at moves for every push and comment, so a cursor would either re-fire a
# still-labelled PR on every tick or miss a label added during a quiet moment.
#
# So `github_label` conditions keep a seen-set instead of a cursor. Each tick asks
# GitHub for the set of open items that currently carry a watched label and keys them
# as "owner/repo#number:label". That set IS the condition's new seen-set; what fires
# is the difference against the old one:
#
#     fire = current_keys - seen_keys        # a label that was not there last tick
#     seen = current_keys                    # (modulo failures — see below)
#
# The semantics that fall out of this, all of which are covered by tests:
#
# - **A still-labelled item never re-fires.** It is in the seen-set on every tick, so
#   it is never again in the difference.
# - **Nothing fires retroactively.** The FIRST tick of a condition records the seen-set
#   and fires nothing. A PR that already carried the label when the trigger was created
#   is absorbed into that baseline. `seen_items` being ABSENT is what marks a condition
#   as un-baselined — a condition whose repos simply have nothing labelled has a
#   present-but-empty set, and must not be baselined a second time.
# - **Adding a repo or a label baselines only that addition.** The companion
#   `baseline_scope` records the repos/target/labels the seen-set was built against, so a
#   widened condition can tell an item that is new to it (its repo was just added — that
#   part of the scope is having its first tick, and is absorbed) from an item that is a
#   real event in a repo it was already watching (fires). Dropping the whole seen-set on
#   any scope edit, which is what this used to do, absorbed both — #647, where a PR
#   labelled a minute after a `repos` edit was recorded as seen and never got a session.
#   A `target` flip is the one change the seen-set cannot survive: a repo numbers issues
#   and PRs from one sequence, so the keys stop denoting the same items and everything is
#   re-baselined.
# - **Re-labelling fires again.** Removing the label drops the key; adding it back makes
#   the key new. That is the honest reading of "the label was added" — it happened twice.
#   A key is not dropped on the FIRST tick it is missing, though: GitHub's search index is
#   eventually consistent, so a still-labelled PR can vanish from one tick's results and
#   return on the next. Dropping it immediately would re-fire a duplicate session (the label
#   poller's version of the index lag the github_issue path below guards against). A missing
#   key is therefore retained through REMOVAL_GRACE_TICKS consecutive misses — tracked in the
#   companion `seen_missing_counts` — and only then accepted as genuinely unlabelled. A real
#   removal simply takes that many ticks to register before a re-add counts as a new event.
# - **A skipped tick is harmless.** The seen-set is state, not a cursor: a missed run
#   changes nothing, because the next run still sees the label and still fires. (A skipped
#   tick also does not advance the removal grace, since misses are only counted on a real
#   poll — so downtime can never expire a key's grace early.)
# - **A closed item drops out** of the `is:open` search and so out of the seen-set. If it
#   is reopened still carrying the label, it fires again — a reopened PR is worth
#   re-evaluating, and the alternative (remembering closed items forever) is unbounded.
#
# The set is bounded by the number of open items carrying a watched label — a handful,
# not the repo's history — so it does not grow without limit.
#
# `github_issue` conditions are genuinely event-shaped: an issue's creation time never
# changes, so those use an ordinary `created_at` cursor. The one wrinkle is that GitHub's
# `created:` qualifier has only second granularity, so a strict `>` would silently drop an
# issue that shared its second with the previous tick's newest. The cursor is therefore
# inclusive (`>=`) and paired with a small set of keys already fired at that exact second.
#
# Because that cursor is re-queried from INDEX_LAG_GRACE behind itself, it cannot on its own
# express "everything that already existed is history": the window reaches straight back
# through the instant a baseline was taken. `issue_repo_baselines` says it separately — when
# each repo joined the scope — so a first poll, and a scope-widening edit, can refuse a repo's
# back catalogue while the grace window stays live for the repos already being watched.
#
# A `github_issue` condition may also carry `exclude_labels` — an opt-out the issue's author
# applies by opening it with one of those labels. It is expressed as a `-label:` negation in
# the search itself, so an excluded issue is never seen, never fires, and never moves the
# cursor. See GithubTriggerSearch#issue_query for the timing this implies.
#
# In both cases state advances only for items that actually produced a session, so a
# failure to create one leaves the item to be retried on the next tick rather than
# swallowing it. And in both cases it advances the moment that session exists rather
# than only in the tick's terminal write — #record_fired_key for the label seen-set,
# #record_fired_issue for the issue cursor and its key set — so a terminal write that
# never lands cannot hand the next tick a batch it has already spawned sessions for.
# The terminal write remains the authority on everything the floor does not do: the
# label path's removal grace, and the issue path's horizon-based pruning.
class GithubTriggerPollerJob < ApplicationJob
  # The `pollers` queue, not `default` — same reasoning as every other *PollerJob: this
  # is slow, external-API-bound work that would otherwise starve the latency-sensitive
  # periodic jobs sharing `default`.
  queue_as :pollers

  # At most one poll in flight (running or queued) at a time. The cron enqueues every
  # minute; a slow tick must not stack against itself. Polling is idempotent — state
  # only advances on success — so a skipped tick is simply picked up by the next run.
  good_job_control_concurrency_with(
    key: -> { "github_trigger_poller" },
    total_limit: 1
  )

  # The fire itself, shared with GithubEventJob so a webhook delivery renders and spawns exactly
  # as a poll does. It brings GithubTriggerSearch, the searches and item readers shared with
  # GithubTriggerHealthCheckJob so the freshness probe asks GitHub exactly what the poller asks.
  include GithubTriggerFiring

  # How far behind its cursor a github_issue condition re-queries, to absorb GitHub's
  # eventually-consistent (and unordered) search index. An issue indexed later than this
  # after being opened is missed; observed lag in practice is on the order of seconds.
  INDEX_LAG_GRACE = 30.minutes

  # The github_label seen-set's defense against that same eventually-consistent index: a
  # seen key that disappears from the search is retained for this many consecutive misses
  # before being accepted as genuinely unlabelled and dropped. A transient under-return (the
  # PR is still open and labelled, GitHub's index just did not return it this tick) is thus
  # absorbed rather than re-firing the item next tick. At the one-minute poll cadence this is
  # roughly three minutes of sustained absence — well beyond observed index blips, yet short
  # enough that a real remove-then-re-add of the label still fires again promptly.
  REMOVAL_GRACE_TICKS = 3

  # How many seen-set keys the baseline-reset alert lists by name. They are there for a
  # human to check by hand, and a Slack block has a hard size limit, so the list is
  # bounded and says when it was cut rather than being truncated mid-key by Slack. The
  # count in the alert's sentence is always the true one.
  MAX_ALERTED_KEYS = 25

  # Liveness heartbeat. Each sweep that processes at least one condition successfully
  # stamps PollerHeartbeat's :github key with the current time; TriggerPollerLivenessCheckJob
  # reads it and pages if it goes stale.
  #
  # The bar is "at least one condition came back clean", NOT "perform returned": the
  # per-condition rescue below swallows errors so one bad condition cannot abort the
  # sweep, which means perform returns normally even in a total outage where nothing was
  # polled at all. Requiring a real success is what distinguishes a working poller (some
  # condition succeeded — a failing one pages on its own) from a wedged/down one or a
  # total GitHub outage — the silent-freeze class the per-tick error alert cannot catch,
  # because no code runs to raise.
  #
  # Nearly every success implies a GitHub search actually returned; the one exception is a
  # github_issue condition's first tick, which baselines its cursor without searching. That
  # can stamp the heartbeat with no GitHub contact, but only for the single tick before the
  # cursor is set, so it costs at most a minute of detection latency.

  # How many consecutive ticks a condition may skip on an incomplete search index before
  # the skips stop being read as a transient and page.
  #
  # GitHub's search index times out occasionally and recovers by itself — on the order of
  # once a month on the busiest condition here, and GithubSearchService has already re-run
  # the search before it gives up — so a single skip is noise, not an incident. Five in a
  # row at a one-minute cadence is not: that is a degradation that is not clearing, and
  # the condition has been dark for five minutes.
  CONSECUTIVE_INCOMPLETE_SEARCHES_TO_ALERT = 5

  # Rails cache (Redis) key holding the current run of consecutive incomplete searches,
  # keyed per condition — per condition because one condition's query being too expensive
  # for the index must not be reset by a cheaper condition succeeding beside it. Any clean
  # poll of that condition clears it, so a streak only survives while it is genuinely
  # unbroken. Same shape as SystemHealthMonitorJob::STREAK_CACHE_KEY.
  INCOMPLETE_SEARCH_STREAK_KEY_PREFIX = "github_trigger_poller:incomplete_search_streak:"

  # Comfortably beyond the tick interval so a missed tick can't silently reset a streak,
  # short enough that a count from an old degradation doesn't linger into a new one.
  INCOMPLETE_SEARCH_STREAK_TTL = 1.hour

  def self.incomplete_search_streak_key(condition_id)
    "#{INCOMPLETE_SEARCH_STREAK_KEY_PREFIX}#{condition_id}"
  end

  # How many consecutive sweeps GitHub may rate-limit before the limit stops reading as a
  # burst and pages.
  #
  # A secondary rate limit is GitHub asking for a pause measured in a minute or two, and
  # this poller's one-minute cadence already IS that pause — the next tick is normally
  # clean, which is why the first occurrence is noise rather than an incident. Production
  # bore that out on 2026-09-09: one occurrence in seven days, self-cleared, one page.
  # Five in a row is a different animal — the fleet is asking for more than GitHub will
  # give it at this cadence, no amount of waiting fixes that, and the triggers have been
  # dark for five minutes. Same shape and same threshold as the incomplete-search streak
  # above, kept as its own constant because the two degradations are free to diverge.
  CONSECUTIVE_RATE_LIMITED_SWEEPS_TO_ALERT = 5

  # Rails cache (Redis) key holding the run of consecutive rate-limited sweeps.
  #
  # Global, where the incomplete-search streak is per condition, because a rate limit is a
  # property of the credential rather than of the query: the sweep stops at the first
  # condition to meet one, so a per-condition streak would only ever count whichever
  # condition sorts first and would never reach its threshold for the rest. Any sweep that
  # finishes without a rate limit clears it, so a streak only survives while unbroken.
  RATE_LIMITED_STREAK_KEY = "github_trigger_poller:rate_limited_streak"

  # Comfortably beyond the tick interval so a missed tick can't silently reset a streak,
  # short enough that a count from an old episode doesn't linger into a new one.
  RATE_LIMITED_STREAK_TTL = 1.hour

  def perform
    conditions = TriggerCondition.github
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .includes(:trigger)

    # Nothing to poll — don't spend a `gh auth status` subprocess every minute on the
    # (common) instance that has no GitHub triggers at all.
    unless conditions.exists?
      # A tick that correctly found nothing to do is still liveness, and stamping it
      # keeps the heartbeat fresh through a period with no GitHub triggers. Otherwise the
      # key would rot while there was legitimately nothing to poll, and enabling a trigger
      # would flip the health check on against that stale value and page for a poller that
      # is working perfectly. This can never mask a real stall: the check reads the
      # heartbeat only when there IS something to poll.
      record_successful_poll
      return
    end

    # Degrade gracefully when the environment has no GitHub credential, exactly as
    # SlackTriggerPollerJob returns early on an unconfigured Slack. Without this, an
    # environment whose worker lacks `gh auth` (e.g. staging) shells out once per
    # condition every tick, each call failing with "please run: gh auth login", and the
    # per-condition rescue below turns every one into an alert — an every-minute storm
    # over a missing credential. One WARN per tick is enough to make the gap visible.
    #
    # The skip is the same for every way the preflight can fail — it has to be, or the
    # storm comes back — but the LOG LINE is not, and that is the whole point. On
    # 2026-08-17 a GitHub degradation made this branch announce "gh CLI is not
    # authenticated" about a credential that was fine minutes either side, in text
    # byte-identical to a revoked token's (#542). An operator cannot act on a line that
    # names the wrong fault, so each state now says what actually happened; the states
    # themselves are established in GithubSearchService.auth_preflight.
    preflight = GithubSearchService.auth_preflight
    unless preflight.authenticated?
      Rails.logger.warn "[GithubTriggerPollerJob] #{preflight_skip_reason(preflight)}; " \
                        "skipping GitHub trigger polling this tick"
      return
    end

    any_polled = false
    # The rate limit that ended this sweep early, if one did, and how many conditions
    # never got their turn because of it.
    rate_limit = nil
    rate_limited_skips = 0

    conditions.find_each do |condition|
      # A rate limit belongs to the credential, not to the condition that happened to
      # meet it, so every condition left in this sweep would spend a `gh` call to be
      # told the same thing — and spend it on the one class of failure that extra
      # requests make worse and longer. Stop asking; the next tick is the retry, and
      # under seen-set semantics a skipped tick costs nothing because the next one
      # re-derives the whole set.
      if rate_limit
        rate_limited_skips += 1
        next
      end

      process_condition(condition)
      any_polled = true
      clear_incomplete_search_streak(condition)
    rescue GithubSearchService::IncompleteResultsError => e
      skip_incomplete_search(condition, e)
    rescue GithubSearchService::RateLimitedError => e
      # The incomplete-search streak is deliberately left alone, neither bumped nor
      # cleared. A rate limit is refused at the edge, so the search never reached the
      # index and this tick holds no verdict about it either way — and the conditions
      # skipped below, spared the call for the same credential-level reason, keep their
      # streaks too. Clearing here would single out whichever condition happened to meet
      # the limit first and could reset a genuine index degradation forever.
      rate_limit = e
    rescue => e
      # Clearing here too is what makes the streak's "consecutive" literal: a tick that
      # failed some other way is not an incomplete-index tick, and it pages on its own
      # below, so it must break the run rather than be counted into it.
      clear_incomplete_search_streak(condition)
      Rails.logger.error "[GithubTriggerPollerJob] Error processing condition #{condition.id}: #{e.message}"
      ErrorReporter.report_exception(
        e,
        context: {
          title: "GitHub trigger poller error",
          source: "GithubTriggerPollerJob",
          details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' " \
                   "(ID: #{condition.trigger_id}) failed.",
          condition_id: condition.id,
          trigger_id: condition.trigger_id
        }
      )
    end

    if rate_limit
      defer_rate_limited_sweep(rate_limit, skipped: rate_limited_skips)
    else
      clear_rate_limited_streak
    end

    # Record the heartbeat only when the poller actually did work — see the constant's
    # comment for why a total-outage sweep (every condition rescued) must NOT count. A
    # rate limit met on the very first condition therefore stamps nothing, which is right:
    # the sweep polled nobody, and TriggerPollerLivenessCheckJob's stale-heartbeat page is
    # the backstop if #defer_rate_limited_sweep's streak alarm somehow does not fire.
    record_successful_poll if any_polled
  end

  private

  # What to tell an operator about a preflight that did not authenticate.
  #
  # Three sentences that must never be swapped for one another, because each sends a
  # human somewhere different: to provision a credential, to replace one, or to
  # githubstatus.com. Only the first keeps the original wording — it is the only state
  # that ever deserved it, and staging's every-minute line stays exactly as it was.
  #
  # No alert fires from any of them, deliberately. A preflight failure is by
  # construction the TOTAL case, and this job already settled how the total case is
  # reported: nothing sets any_polled, so no heartbeat is stamped, and
  # TriggerPollerLivenessCheckJob pages on the stale heartbeat (see #skip_incomplete_search,
  # which reasons the same way about a broadly degraded search API — "no new machinery
  # needed for the total case"). Paging on the first :unknown tick would page for every
  # blip, and would put an alert back on exactly the path whose alert storm the early
  # return was built to stop, on the strength of a classification that has to be right
  # every time. The 15-minute floor is unchanged; what changes is that the WARNs an
  # operator reads while it counts down now name the right fault.
  def preflight_skip_reason(preflight)
    case preflight.state
    when GithubSearchService::PREFLIGHT_UNCONFIGURED
      "gh CLI is not authenticated (no gh auth login / GH_TOKEN)"
    when GithubSearchService::PREFLIGHT_REJECTED
      "GitHub rejected the gh credential — it is present but no longer valid, so it likely " \
        "needs rotating (#{preflight.detail})"
    else
      # :unknown. Says what we do NOT know, on purpose: asserting anything about the
      # credential here is the bug. The credential may well be fine.
      "could not reach GitHub to check the gh credential, so its validity is UNKNOWN — this is " \
        "NOT a report that the credential is missing or invalid; check githubstatus.com before " \
        "touching it (#{preflight.detail})"
    end
  end

  def record_successful_poll
    PollerHeartbeat.stamp(:github)
  end

  # A search whose index timed out is refused exactly like any other short read — the
  # seen-set is never derived from a partial result, which is the whole point of the raise
  # in GithubSearchService — but on its own it is not an incident worth a human's evening.
  # GitHub's index recovers by itself, the service has already re-run the search, and the
  # next tick re-derives the entire seen-set from scratch, so a skipped tick costs nothing
  # and self-corrects. This is the same distinction `GithubSearchService.configured?`
  # draws between "not an incident, skip quietly" and "a real failure, raise and alert".
  #
  # Sustained degradation still surfaces, by two independent routes:
  #   - this condition alone (an expensive query the index keeps timing out on): the
  #     consecutive-skip streak below crosses CONSECUTIVE_INCOMPLETE_SEARCHES_TO_ALERT
  #     and pages;
  #   - every condition at once (GitHub search broadly degraded): nothing sets any_polled,
  #     so the heartbeat is never stamped, and TriggerPollerLivenessCheckJob pages when it
  #     goes stale — no new machinery needed for the total case.
  #
  # A cache that cannot be read degrades to "always quiet" rather than "always page": the
  # streak is the only thing that escalates, and inventing one from a failed read would
  # page for a Redis blip on the first incomplete search — reintroducing exactly the noise
  # this exists to remove. A dead cache is its own, separately monitored fault.
  def skip_incomplete_search(condition, error)
    streak = bump_incomplete_search_streak(condition)

    if streak.nil? || streak < CONSECUTIVE_INCOMPLETE_SEARCHES_TO_ALERT
      run = streak ? "#{streak} consecutive" : "streak untracked"

      # .warn, not .error: an ERROR record pages on its own (see the logging
      # philosophy), and a self-healing blip is not worth a page.
      Rails.logger.warn "[GithubTriggerPollerJob] GitHub's search index returned incomplete " \
                        "results for condition #{condition.id} (#{run}); skipping it this " \
                        "tick — the next tick re-derives the full seen-set"
      return
    end

    # .error past the streak threshold: this line IS the page.
    Rails.logger.error "[GithubTriggerPollerJob] GitHub's search index has returned incomplete " \
                       "results for condition #{condition.id} on #{streak} consecutive ticks"
    ErrorReporter.report_exception(
      error,
      context: {
        title: "GitHub search index degraded",
        source: "GithubTriggerPollerJob",
        details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' " \
                 "(ID: #{condition.trigger_id}) has been skipped for #{streak} consecutive ticks " \
                 "because GitHub's search API keeps returning incomplete results. Its items are " \
                 "not being polled, so this trigger is not firing. A single occurrence is a normal " \
                 "self-healing blip; this many in a row is not. Check githubstatus.com, and whether " \
                 "the condition's query has grown expensive enough to time the index out.",
        condition_id: condition.id,
        trigger_id: condition.trigger_id,
        consecutive_ticks: streak
      }
    )
  end

  # The new streak length, or nil when the cache could not be reached.
  def bump_incomplete_search_streak(condition)
    key = self.class.incomplete_search_streak_key(condition.id)
    streak = Rails.cache.read(key).to_i + 1
    Rails.cache.write(key, streak, expires_in: INCOMPLETE_SEARCH_STREAK_TTL)
    streak
  rescue => e
    Rails.logger.warn "[GithubTriggerPollerJob] Failed to track incomplete-search streak " \
                      "for condition #{condition.id}: #{e.message}"
    nil
  end

  # Rescued for the same reason record_successful_poll is: a cache hiccup must never
  # convert a poll that actually worked into a per-condition alert.
  def clear_incomplete_search_streak(condition)
    Rails.cache.delete(self.class.incomplete_search_streak_key(condition.id))
  rescue => e
    Rails.logger.warn "[GithubTriggerPollerJob] Failed to clear incomplete-search streak " \
                      "for condition #{condition.id}: #{e.message}"
  end

  # GitHub rate-limited the search API and this sweep stopped where it stood.
  #
  # Not a page on its own. A secondary rate limit is a back-off-and-retry condition the
  # fleet is expected to bump into and ride out, and the poller's own cadence is the
  # back-off — so the first occurrences get a WARN and a skipped tick, the treatment the
  # Slack poller has given its own 429s since #509. What still pages is a limit that is
  # not clearing, on the streak the constant explains.
  #
  # A cache that cannot be read degrades to "always quiet" rather than "always page", for
  # the same reason bump_incomplete_search_streak does: inventing a streak from a failed
  # read would page for a Redis blip on the first rate limit, which is the noise this
  # exists to remove. A dead cache is its own, separately monitored fault.
  def defer_rate_limited_sweep(error, skipped:)
    streak = bump_rate_limited_streak
    remainder = skipped.zero? ? "" : "; #{skipped} further condition#{'s' unless skipped == 1} not polled this tick"

    if streak.nil? || streak < CONSECUTIVE_RATE_LIMITED_SWEEPS_TO_ALERT
      run = streak ? "#{streak} consecutive" : "streak untracked"

      # .warn, not .error: an ERROR record pages on its own (see the logging
      # philosophy), and a self-clearing burst limit is not worth a page.
      Rails.logger.warn "[GithubTriggerPollerJob] GitHub rate-limited the search API " \
                        "(#{run}); skipping the rest of this sweep — the next tick is " \
                        "the retry#{remainder}. #{error.message}"
      return
    end

    # .error past the streak threshold: this line IS the page.
    Rails.logger.error "[GithubTriggerPollerJob] GitHub has rate-limited the search API on " \
                       "#{streak} consecutive ticks"
    ErrorReporter.report_exception(
      error,
      context: {
        title: "GitHub search API rate limit not clearing",
        source: "GithubTriggerPollerJob",
        details: "GitHub has rate-limited `gh api search/issues` on #{streak} consecutive ticks. Each " \
                 "of those sweeps stopped at the condition that met the limit, so GitHub triggers have " \
                 "been going unpolled for that long and are firing late or not at all. A single " \
                 "occurrence is a normal, self-clearing burst limit; this many in a row means " \
                 "the fleet is asking for more than GitHub will serve at this cadence. Check " \
                 "githubstatus.com, and what else is spending this credential's search quota.",
        consecutive_ticks: streak
      }
    )
  end

  # The new streak length, or nil when the cache could not be reached.
  def bump_rate_limited_streak
    streak = Rails.cache.read(RATE_LIMITED_STREAK_KEY).to_i + 1
    Rails.cache.write(RATE_LIMITED_STREAK_KEY, streak, expires_in: RATE_LIMITED_STREAK_TTL)
    streak
  rescue => e
    Rails.logger.warn "[GithubTriggerPollerJob] Failed to track rate-limited streak: #{e.message}"
    nil
  end

  # Rescued for the same reason clear_incomplete_search_streak is: a cache hiccup must
  # never convert a sweep that actually worked into an alert.
  def clear_rate_limited_streak
    Rails.cache.delete(RATE_LIMITED_STREAK_KEY)
  rescue => e
    Rails.logger.warn "[GithubTriggerPollerJob] Failed to clear rate-limited streak: #{e.message}"
  end

  def process_condition(condition)
    case condition.condition_type
    when "github_label" then process_label_condition(condition)
    when "github_issue" then process_new_issue_condition(condition)
    end
  end

  # ── github_label ────────────────────────────────────────────────────────────

  def process_label_condition(condition)
    scope = condition.github_watch_scope

    # Sorted, so pagination is stable. GitHub's default best-match order is not stable
    # across page fetches, and for a condition matching >100 items an item that shuffled
    # between pages would drop out of current_keys, leave the seen-set, and re-fire.
    items = GithubSearchService.search_issues(label_query(condition), sort: "created", order: "asc")

    # One key per (item, label). Watching two labels and having both added is two distinct
    # "the label was added" events; keying by item alone would swallow the second forever.
    #
    # Labels are matched case-INSENSITIVELY, and the key uses the configured casing rather
    # than GitHub's. GitHub's `label:` search qualifier already ignores case, so a user who
    # types "Ready To Merge" for a repo label named "ready to merge" gets the item back from
    # the search — and an exact-string filter here would then discard it, leaving a condition
    # that silently never fires with nothing in the logs to say why.
    watched = condition.github_labels.index_by { |label| label.downcase }
    candidates = {}
    items.each do |item|
      labels_for(item).each do |label|
        configured = watched[label.downcase]
        candidates["#{item_key(item)}:#{configured}"] = [ item, configured ] if configured
      end
    end
    current_keys = candidates.keys.to_set

    if !condition.github_baselined? || condition.github_baseline_retargeted?
      baseline_everything(condition, scope, current_keys)
      return
    end

    seen = condition.github_seen_items.to_set
    missing_counts = condition.github_seen_missing_counts

    # Items that are in the result set only because the condition's scope just grew.
    # A repo (or a label) added to a live condition has never been baselined, so what it
    # already carries is pre-existing state rather than events — absorbing it is the same
    # rule as "the first tick fires nothing", applied to the part of the scope that is
    # having its first tick. Everything OUTSIDE the newly-added part still fires, which
    # is what #647 lost when the whole seen-set was dropped on any scope edit.
    absorbed = Set.new
    candidates.each do |key, (item, label)|
      next if seen.include?(key)
      absorbed << key unless condition.github_baseline_covers?(repo_of(item), label)
    end

    if absorbed.any?
      Rails.logger.info "[GithubTriggerPollerJob] Condition #{condition.id} watches more than its " \
                        "baseline covers; absorbing #{absorbed.size} already-labelled item(s) from the " \
                        "newly-watched scope without firing"
    end

    # Keys we already knew about AND that still carry the label. These are confirmed
    # present, so any miss streak they were carrying is cleared below.
    retained = current_keys & seen
    fired = Set.new

    (current_keys - seen - absorbed).sort.each do |key|
      item, label = candidates[key]
      next unless fire(condition, item, event: "label added: #{label}")

      fired << key
      # Record the key the instant its session exists, rather than only in the
      # end-of-tick write below. Everything between here and there can fail —
      # another key's fire, the reload in #write_state, the update! itself, or the
      # worker being torn down mid-tick — and every one of those failures loses a
      # key whose session was already created. The next tick then sees it as new
      # and spawns a second session for the same label. See #record_fired_key.
      record_fired_key(condition, scope, key)
    end

    # A key that was seen but is absent this tick is NOT dropped on sight. GitHub's search
    # index is eventually consistent, so a still-labelled PR can vanish from one tick's
    # results and return on the next; dropping its key immediately makes it look new again
    # and re-fires a duplicate session — the label poller's version of the index-lag the
    # github_issue path guards against. Instead we retain the key through REMOVAL_GRACE_TICKS
    # consecutive misses, and only once it has been absent that long do we accept the label
    # as genuinely removed and drop it — at which point a real remove-then-re-add fires again.
    grace_retained = Set.new
    next_missing = {}
    (seen - current_keys).each do |key|
      misses = missing_counts.fetch(key, 0) + 1
      next if misses >= REMOVAL_GRACE_TICKS

      grace_retained << key
      next_missing[key] = misses
    end

    # Keys that failed to produce a session are in neither retained, fired, grace_retained
    # nor absorbed, so the next tick sees them as new again and retries.
    write_state(
      condition, scope,
      {
        "seen_items" => (retained + fired + grace_retained + absorbed).to_a.sort,
        "seen_missing_counts" => next_missing,
        "baseline_scope" => condition.github_scope_snapshot
      },
      fired: fired.any?
    )
  end

  # Record the whole current result set as the baseline and fire nothing.
  #
  # Two conditions arrive here. The FIRST tick of a condition, which is the designed
  # behavior: a PR that already carried the label when the trigger was created is history,
  # not an event. And a condition whose `target` flipped between PRs and issues, where the
  # seen-set's keys no longer denote the same items.
  #
  # There is a third way in, and it is the one worth an alert: a condition that has polled
  # before and has come back with NO seen-set at all. Editing the condition is no longer a
  # route to that (#647 — an edit now keeps the seen-set), so what is left is a hand-edited
  # row or a bug, and the cost is exactly #647's: any item labelled since the set was lost
  # is absorbed here rather than fired, permanently and with nothing to say so.
  #
  # It absorbs rather than fires on purpose. Firing for everything currently labelled at a
  # fresh baseline is the opposite failure and the worse one here: on the merge gate — the
  # condition #647 was observed on, and the one mechanism authorized to merge without human
  # sign-off — it would spawn a gate session per already-labelled PR, against PRs long since
  # handled. Absorbing costs at most the items labelled since the set was lost; firing costs
  # a session per open labelled PR in every watched repo. So the reset stays conservative
  # and stops being SILENT instead: it alerts, naming what it swallowed, which is what makes
  # the manual remedy (`action_trigger` `invoke`) reachable.
  def baseline_everything(condition, scope, current_keys)
    lost_baseline = !condition.github_baselined? && condition.last_polled_at.present?

    write_state(
      condition, scope,
      {
        "seen_items" => current_keys.to_a.sort,
        "seen_missing_counts" => {},
        "baseline_scope" => condition.github_scope_snapshot
      }
    )

    Rails.logger.info "[GithubTriggerPollerJob] Baselined condition #{condition.id} " \
                      "with #{current_keys.size} already-labelled item(s); firing none"
    return unless lost_baseline && current_keys.any?

    details = "Condition #{condition.id} on trigger '#{condition.trigger&.name}' " \
              "(ID: #{condition.trigger_id}) had already polled but came back with no seen-set, so it " \
              "has been re-baselined against the #{current_keys.size} item(s) currently labelled: " \
              "#{listed_keys(current_keys)}. Any of them that gained the label after the " \
              "seen-set was lost has been absorbed as already-seen and will NOT get a session. Check " \
              "them for a missing session and use action_trigger `invoke` for any that never fired."

    Rails.logger.error "[GithubTriggerPollerJob] GitHub trigger baseline was reset: #{details}"
    ErrorReporter.report_message(
      "GitHub trigger baseline was reset",
      level: :error,
      context: {
        source: "GithubTriggerPollerJob",
        details: details,
        condition_id: condition.id,
        trigger_id: condition.trigger_id
      }
    )
  end

  def listed_keys(keys)
    listed = keys.to_a.sort
    return listed.join(", ") if listed.size <= MAX_ALERTED_KEYS

    "#{listed.first(MAX_ALERTED_KEYS).join(', ')} (+#{listed.size - MAX_ALERTED_KEYS} more)"
  end

  # Persist ONE fired key, on its own, immediately after its session was created.
  #
  # The end-of-tick #write_state is still the authority on the whole seen-set: it
  # is what maintains `seen_missing_counts` and what drops keys whose grace has
  # run out. This is only the durability floor underneath it — the guarantee that
  # a key whose session exists cannot come back as new, whatever happens to the
  # rest of the tick.
  #
  # It only ever ADDS a key that just fired, so it cannot resurrect a key the
  # grace window was about to drop, and it cannot suppress a fire: an item that
  # did not produce a session is never passed here and is still left unseen for
  # the next tick to retry. That direction matters — #647 is the opposite failure,
  # a real label event swallowed, and it is the worse of the two.
  #
  # `fired: true` for the same reason #write_github_state! folds last_triggered_at
  # into the state write: the trigger fired, and the two must not disagree.
  #
  # Rescued rather than raised. A failure here costs exactly what today's code
  # costs — the end-of-tick write is still coming — so it must not abort a tick
  # that is otherwise working.
  #
  # The #reload drops the condition's association cache, so every item after the
  # first in a tick re-reads its trigger. That is correct rather than merely
  # tolerable: all the state a fire consults across items — the burst window and
  # latch, `last_session_id`, the missed-fire count — is DB-backed and taken under
  # a row lock, so a fresh instance reads the same answer. Nothing here may depend
  # on instance memoization surviving the loop.
  def record_fired_key(condition, scope, key)
    condition.reload

    # Same mid-poll re-scope check #write_state makes, for the same reason: a
    # condition the user re-pointed while this tick was in flight is being
    # re-baselined, and this tick's keys are not part of that baseline.
    return if condition.github_watch_scope != scope
    return if condition.github_seen_items.include?(key)

    condition.write_github_state!(
      { "seen_items" => (condition.github_seen_items + [ key ]).sort },
      fired: true
    )
  rescue => e
    Rails.logger.warn "[GithubTriggerPollerJob] Could not record fired key #{key} for condition " \
                      "#{condition.id} immediately (#{e.message}); the end-of-tick write is the fallback"
  end

  # ── github_issue ────────────────────────────────────────────────────────────

  def process_new_issue_condition(condition)
    scope = condition.github_watch_scope
    cursor = condition.github_last_issue_at

    # First tick: start the clock. Issues that predate the condition are history, not
    # events this trigger was created to react to.
    #
    # Saying that with the cursor alone does not hold, because the next tick queries
    # INDEX_LAG_GRACE *behind* it: "now" as a cursor still returns the last 30 minutes, and
    # with nothing to reject them they read as fresh. So the baseline records what already
    # existed as well as when — per repo, by creation time — and the window is free to keep
    # reaching back.
    if cursor.blank?
      now = Time.current.utc.iso8601
      write_state(
        condition, scope,
        { "last_issue_at" => now, "seen_issue_keys" => [],
          "issue_repo_baselines" => baselines_for_all_watched(condition, now) }
      )
      Rails.logger.info "[GithubTriggerPollerJob] Baselined condition #{condition.id} at #{now}; firing none"
      return
    end

    # Query from BEFORE the cursor, not from it. GitHub's search index is eventually
    # consistent and not ordered: of two issues opened seconds apart, the newer can be
    # indexed first. A bare `created:>=cursor` would fire the newer one, advance the cursor
    # past it, and then never see the older one when it finally appears — a silent, permanent
    # miss. Re-querying a INDEX_LAG_GRACE-wide window behind the cursor means a late-indexed
    # issue is still inside the window when it shows up; seen_issue_keys (which covers the
    # whole window, not just the cursor's second) is what keeps it from firing twice.
    window_start = (Time.iso8601(cursor) - INDEX_LAG_GRACE).utc.iso8601

    query = issue_query(condition, window_start)

    # Ascending, so the cursor advances through the batch and stops cleanly at the first
    # item that fails to produce a session.
    items = GithubSearchService.search_issues(query, sort: "created", order: "asc")
    return if items.empty?

    already_fired = condition.github_seen_issue_keys.to_set
    baselines = condition.github_issue_repo_baselines

    # Two ways an item in the window is not an event. It has already fired — that is the
    # seen-set's job, and it is why the window can be re-queried at all. Or it predates the
    # baseline of the repo it is in, which is how a repo joins the scope without dragging
    # its whole history in behind it. Neither is recorded as fired: a pre-baseline issue is
    # rejected by the same comparison on every tick, so there is nothing to remember.
    fresh = items.reject do |item|
      already_fired.include?(item_key(item)) || predates_repo_baseline?(item, baselines)
    end
    return if fresh.empty?

    newest_at = cursor
    fired_keys = already_fired.dup

    fresh.each do |item|
      break unless fire(condition, item, event: "issue opened")

      fired_keys << item_key(item)
      newest_at = item["created_at"] if item["created_at"].to_s > newest_at.to_s
      # Record the fire the instant its session exists, rather than only in the
      # end-of-tick write below. Everything between here and there can fail — a later
      # item's fire, the re-read #write_new_issue_state does, the write itself, or the
      # worker being torn down mid-tick — and every one of those failures used to leave
      # BOTH pieces of this condition's dedupe state untouched, handing the next tick
      # the whole batch as un-fired. See #record_fired_issue.
      record_fired_issue(condition, scope, item, fired_keys)
    end

    # Nothing fired: leave the cursor alone so the whole batch is retried next tick.
    return if fired_keys == already_fired

    # Remember every fired issue still inside the lag window we will re-query next tick.
    # Anything older than the window can never come back, so it is dropped — which is what
    # bounds this set to "issues opened in the last INDEX_LAG_GRACE" rather than forever.
    horizon = (Time.iso8601(newest_at) - INDEX_LAG_GRACE).utc.iso8601
    retained_keys = items
      .select { |item| fired_keys.include?(item_key(item)) && item["created_at"].to_s >= horizon }
      .map { |item| item_key(item) }
      .uniq
      .sort

    # A repo baseline is spent once the window no longer reaches back past it: `horizon` is
    # exactly where the next tick's query starts, so an entry at or before it can never
    # match another item. Dropping it there bounds the map the same way the horizon bounds
    # the seen-set. A quiet condition whose window holds only pre-baseline issues never
    # reaches this write at all, so its entries sit until something fires — harmless, and
    # the reason the map is a few short strings rather than a store.
    write_new_issue_state(
      condition, scope,
      { "last_issue_at" => newest_at, "seen_issue_keys" => retained_keys,
        "issue_repo_baselines" => baselines.select { |_repo, at| at.to_s > horizon } },
      fired_items: items.select { |item| fired_keys.include?(item_key(item)) }
    )
  end

  # Record what this tick has fired so far — every key in `fired_keys`, and the cursor if
  # +item+ is the newest of them — immediately after +item+'s session was created.
  #
  # #record_fired_key with a second field to carry. A `github_issue` condition dedupes on
  # a cursor AND a key set, and moving the cursor without the keys is the unsafe half: the
  # window advances past issues nothing remembers firing, and everything sharing the
  # cursor's second fires again. So both move in one write, and both move only past an
  # item that demonstrably produced a session — #fire returns true only when one exists,
  # which is what keeps this on the safe side of #647. An issue that produced nothing is
  # never passed here and is still left un-fired for the next tick to retry.
  #
  # It writes the whole running set rather than the one key, and that is what makes a
  # rescued write recoverable instead of merely survivable. A single-key write leaves this
  # hole: #50's write is lost, #51's lands and carries the cursor to 09:00:05 — but the
  # next query starts INDEX_LAG_GRACE *behind* that, so #50 is squarely inside the window
  # with no key to reject it, and re-fires. Writing the union heals it, because every
  # later fire in the tick re-states every earlier one. `fired_keys` holds only keys that
  # produced a session, so the union is still add-only.
  #
  # The end-of-tick #write_new_issue_state stays the authority on horizon-based pruning:
  # it is what drops keys the next query's window can no longer reach and what expires
  # spent repo baselines. This only ever ADDS keys and only ever advances the cursor
  # forward, so it can neither resurrect a key that write was about to prune nor suppress
  # a fire. The cost of never dropping is that a condition whose floor writes land while
  # its terminal write persistently fails accumulates keys — bounded by the issues it
  # actually fires, and pruned by the first terminal write that does land. Pruning here
  # instead would make this a write that can REMOVE a key, which is the one direction a
  # durability floor may not have.
  #
  # The cursor is compared against the RELOADED row rather than against the loop's running
  # maximum, so a write rescued away here does not carry a stale maximum into the next
  # one. Items arrive in ascending `created_at` and the loop breaks on the first failure,
  # so everything at or before the cursor this advances to has fired.
  #
  # Rescued rather than raised, for the same reason as the label path: a failure here
  # costs exactly what today's code costs — the end-of-tick write is still coming, and so
  # is the next fire's — so it must not abort a tick that is otherwise working.
  def record_fired_issue(condition, scope, item, fired_keys)
    condition.reload

    # Same mid-poll re-scope check the writes make: a condition the user re-pointed while
    # this tick was in flight has rebased its own cursor, and this tick's cursor is not
    # part of that rebase. Its KEYS still are, and #write_new_issue_state below is what
    # carries those across — it is reached whatever this does.
    return if condition.github_watch_scope != scope

    created_at = item["created_at"].to_s
    keys = condition.github_seen_issue_keys | fired_keys.to_a

    state = {}
    state["seen_issue_keys"] = keys.sort unless keys.to_set == condition.github_seen_issue_keys.to_set
    state["last_issue_at"] = created_at if created_at > condition.github_last_issue_at.to_s
    return if state.empty?

    # `fired: true` for the same reason #write_github_state! folds last_triggered_at into
    # the state write: the trigger fired, and the two must not disagree.
    condition.write_github_state!(state, fired: true)
  rescue => e
    Rails.logger.warn "[GithubTriggerPollerJob] Could not record fired issue #{item_key(item)} for " \
                      "condition #{condition.id} immediately (#{e.message}); the end-of-tick write " \
                      "is the fallback"
  end

  # #write_state, plus the one thing a `github_issue` tick may not discard on a mid-poll
  # re-scope: the keys it has already fired.
  #
  # The cursor and the baselines are computed against the scope the tick started with, so a
  # re-scope invalidates them and the edit has rebased them itself — dropping them is right,
  # and is what #write_state does. "A session already exists for this issue" is not scope-
  # dependent, though, and the rebased cursor still re-queries the window those issues sit
  # in. Discarding their keys with the rest of the write is therefore #759 again through a
  # seconds-wide door: the tick's own fires come back as duplicates on the next one.
  #
  # #record_fired_issue has already persisted each key as it fired — but on the same scope
  # check, so it no-ops for every item that fired AFTER the edit landed. Those keys have
  # nowhere else to be written, which is why this branch still exists rather than
  # deferring to the floor.
  def write_new_issue_state(condition, scope, state, fired_items:)
    condition.reload

    if condition.github_watch_scope == scope
      condition.write_github_state!(state, fired: true)
      return
    end

    # Bounded by the REBASED cursor's window, on the same rule the discarded write used:
    # a key for an issue the next query cannot return can never reject anything.
    cursor = condition.github_last_issue_at
    horizon = cursor.present? ? (Time.iso8601(cursor) - INDEX_LAG_GRACE).utc.iso8601 : nil
    keys = fired_items
      .select { |item| horizon.nil? || item["created_at"].to_s >= horizon }
      .map { |item| item_key(item) }

    Rails.logger.info "[GithubTriggerPollerJob] Condition #{condition.id} was re-scoped mid-poll; " \
                      "discarding this tick's cursor but keeping #{keys.size} fired key(s)"

    condition.write_github_state!(
      { "seen_issue_keys" => (condition.github_seen_issue_keys | keys).sort },
      fired: true
    )
  end

  # Every watched repo baselined at the same instant — the shape a first tick stamps,
  # where nothing that existed when the condition did is an event.
  #
  # That instant is the condition's own `created_at`, NOT "now". The poll runs up to a
  # minute after the condition was saved, and an issue opened in between was opened after
  # the condition existed: it is an event, and baselining at the tick would drop it
  # silently. Same reasoning as rebasing a widened scope at the edit rather than at the
  # next tick — see TriggerCondition#rebase_github_issue_cursor.
  #
  # Clamped to the window at both ends. The floor, because a condition can reach its first
  # poll long after it was created (a disabled trigger, a poller outage) and the query never
  # reaches further back than INDEX_LAG_GRACE anyway — an older baseline suppresses nothing,
  # so the floor changes no outcome and just keeps the stored instant meaningful. The
  # ceiling, because a baseline ahead of the tick would suppress issues opened between the
  # two, and nothing about a clock that disagrees with `created_at` should cost an event.
  def baselines_for_all_watched(condition, at)
    now = Time.iso8601(at)
    baseline = condition.created_at.utc.clamp(now - INDEX_LAG_GRACE, now).utc.iso8601

    condition.github_repos.to_h { |repo| [ repo.to_s.downcase, baseline ] }
  end

  # Persist poller state, unless the user changed what the condition watches while this tick
  # was in flight.
  #
  # A tick holds its `configuration` hash across a GitHub search and N session creations —
  # seconds. If a UI edit lands in that window it re-baselines the condition (dropping the
  # cursor keys), and a blind merge of our now-stale hash would both undo that re-baseline and
  # revert the user's repo/label edit. Re-reading the row and comparing the watched scope
  # closes it: when the scope moved, we drop this tick's state on the floor and let the next
  # tick baseline against what the user actually asked for.
  def write_state(condition, scope, state, fired: false)
    condition.reload

    if condition.github_watch_scope != scope
      Rails.logger.info "[GithubTriggerPollerJob] Condition #{condition.id} was re-scoped mid-poll; " \
                        "discarding this tick's state so the next one re-baselines"
      return
    end

    condition.write_github_state!(state, fired: fired)
  end
end
