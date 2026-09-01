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
# A `github_issue` condition may also carry `exclude_labels` — an opt-out the issue's author
# applies by opening it with one of those labels. It is expressed as a `-label:` negation in
# the search itself, so an excluded issue is never seen, never fires, and never moves the
# cursor. See #issue_query for the timing this implies.
#
# In both cases state advances only for items that actually produced a session, so a
# failure to create one leaves the item to be retried on the next tick rather than
# swallowing it.
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

  # Bodies are pasted into the prompt verbatim. A pathological issue body should not
  # blow out the session's context before the agent has read its instructions.
  MAX_BODY_LENGTH = 10_000

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

  # Liveness heartbeat. Each sweep that processes at least one condition successfully
  # stamps this Rails.cache (Redis) key with the current time; GithubTriggerHealthCheckJob
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
  HEARTBEAT_CACHE_KEY = "github_trigger_poller:last_successful_poll_at"

  # Generous TTL so the key survives a multi-hour poller outage holding its LAST-success
  # timestamp — that stale value is exactly what the health check needs to read to know
  # polling has stopped. If the key instead expired mid-outage the check would see an
  # absence it can't date and stay quiet. Well beyond any outage we expect to page on;
  # a healthy poller rewrites it every minute.
  HEARTBEAT_TTL = 7.days

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
    AlertBatcher.with_batch do
      conditions.find_each do |condition|
        process_condition(condition)
        any_polled = true
        clear_incomplete_search_streak(condition)
      rescue GithubSearchService::IncompleteResultsError => e
        skip_incomplete_search(condition, e)
      rescue => e
        # Clearing here too is what makes the streak's "consecutive" literal: a tick that
        # failed some other way is not an incomplete-index tick, and it pages on its own
        # below, so it must break the run rather than be counted into it.
        clear_incomplete_search_streak(condition)
        Rails.logger.error "[GithubTriggerPollerJob] Error processing condition #{condition.id}: #{e.message}"
        AlertService.raise_alert(
          "GitHub trigger poller error",
          details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' " \
                   "(ID: #{condition.trigger_id}) failed.",
          source: "GithubTriggerPollerJob",
          dedup_key: "github_trigger_condition_#{condition.id}",
          error: e
        )
      end
    end

    # Record the heartbeat only when the poller actually did work — see the constant's
    # comment for why a total-outage sweep (every condition rescued) must NOT count.
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
  # GithubTriggerHealthCheckJob pages on the stale heartbeat (see #skip_incomplete_search,
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
    Rails.cache.write(HEARTBEAT_CACHE_KEY, Time.current.utc.iso8601, expires_in: HEARTBEAT_TTL)
  rescue => e
    # A cache write failure must never take down a poll that otherwise succeeded; the
    # health check tolerates a missing/stale heartbeat (it seeds and skips) far better
    # than the poll tolerates an exception here.
    Rails.logger.warn "[GithubTriggerPollerJob] Failed to record poll heartbeat: #{e.message}"
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
  #     so the heartbeat is never stamped, and GithubTriggerHealthCheckJob pages when it
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

      # .warn, not .error: an ERROR line pages #alerts on its own (see the logging
      # philosophy), which would leave this every bit as noisy as the alert it replaces.
      Rails.logger.warn "[GithubTriggerPollerJob] GitHub's search index returned incomplete " \
                        "results for condition #{condition.id} (#{run}); skipping it this " \
                        "tick — the next tick re-derives the full seen-set"
      return
    end

    Rails.logger.warn "[GithubTriggerPollerJob] GitHub's search index has returned incomplete " \
                      "results for condition #{condition.id} on #{streak} consecutive ticks; " \
                      "alerting #eng-alerts."
    AlertService.raise_alert(
      "GitHub search index degraded",
      details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' " \
               "(ID: #{condition.trigger_id}) has been skipped for #{streak} consecutive ticks " \
               "because GitHub's search API keeps returning incomplete results. Its items are " \
               "not being polled, so this trigger is not firing. A single occurrence is a normal " \
               "self-healing blip; this many in a row is not. Check githubstatus.com, and whether " \
               "the condition's query has grown expensive enough to time the index out.",
      source: "GithubTriggerPollerJob",
      dedup_key: "github_search_incomplete_results_#{condition.id}",
      error: error
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

    unless condition.github_baselined?
      write_state(condition, scope, { "seen_items" => current_keys.to_a.sort, "seen_missing_counts" => {} })
      Rails.logger.info "[GithubTriggerPollerJob] Baselined condition #{condition.id} " \
                        "with #{current_keys.size} already-labelled item(s); firing none"
      return
    end

    seen = condition.github_seen_items.to_set
    missing_counts = condition.github_seen_missing_counts

    # Keys we already knew about AND that still carry the label. These are confirmed
    # present, so any miss streak they were carrying is cleared below.
    retained = current_keys & seen
    fired = Set.new

    (current_keys - seen).sort.each do |key|
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

    # Keys that failed to produce a session are in neither retained, fired, nor grace_retained,
    # so the next tick sees them as new again and retries.
    write_state(
      condition, scope,
      { "seen_items" => (retained + fired + grace_retained).to_a.sort, "seen_missing_counts" => next_missing },
      fired: fired.any?
    )
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

  def label_query(condition)
    [
      "is:open",
      condition.github_pull_requests? ? "is:pr" : "is:issue",
      GithubSearchService.repo_group(condition.github_repos),
      GithubSearchService.label_group(condition.github_labels)
    ].join(" ")
  end

  # ── github_issue ────────────────────────────────────────────────────────────

  def process_new_issue_condition(condition)
    scope = condition.github_watch_scope
    cursor = condition.github_last_issue_at

    # First tick: start the clock. Issues that predate the condition are history, not
    # events this trigger was created to react to.
    if cursor.blank?
      now = Time.current.utc.iso8601
      write_state(condition, scope, { "last_issue_at" => now, "seen_issue_keys" => [] })
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
    fresh = items.reject { |item| already_fired.include?(item_key(item)) }
    return if fresh.empty?

    newest_at = cursor
    fired_keys = already_fired.dup

    fresh.each do |item|
      break unless fire(condition, item, event: "issue opened")

      fired_keys << item_key(item)
      newest_at = item["created_at"] if item["created_at"].to_s > newest_at.to_s
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

    write_state(
      condition, scope,
      { "last_issue_at" => newest_at, "seen_issue_keys" => retained_keys },
      fired: true
    )
  end

  # The exclusion is applied by the SEARCH, not by filtering what comes back, so an
  # excluded issue never enters the tick at all: it is not fired, and — because the
  # cursor only ever advances past issues that fired — it does not drag the cursor
  # forward either. An issue held back this way is simply never an event.
  #
  # The consequence worth knowing is that the label has to be there when GitHub indexes
  # the issue, which in practice means at creation (`gh issue create --label …`). The
  # poller ticks every minute, so a label added a minute later can lose the race.
  def issue_query(condition, window_start)
    [
      "is:issue",
      GithubSearchService.repo_group(condition.github_repos),
      "created:>=#{window_start}",
      GithubSearchService.exclude_label_terms(condition.github_exclude_labels)
    ].reject(&:blank?).join(" ")
  end

  # ── Firing ──────────────────────────────────────────────────────────────────

  # Creates the session for one item. Returns true only if a session was created, since
  # the caller uses that to decide whether it may advance its state past this item.
  def fire(condition, item, event:)
    trigger = condition.trigger

    prompt = trigger.interpolate_prompt(
      link: item["html_url"],
      text: body_of(item),
      author: item.dig("user", "login"),
      event: event,
      repo: repo_of(item),
      number: item["number"],
      title: item["title"],
      labels: labels_for(item)
    )

    # A template that names no GitHub variable would otherwise hand the session a prompt
    # with no idea which PR it is about. Append the item rather than firing blind.
    prompt = "#{prompt}\n\n#{context_block(item, event: event)}" unless trigger.references_github_context?

    # Set immediately before the call, and read only in the rescue below.
    # #create_session! clears the trigger's created-session marker on entry, so the
    # marker is a true report of THIS fire — but only once we are inside it. A raise
    # before that (interpolation, the context block) would otherwise read the marker
    # left by the PREVIOUS item in this same tick, on this same trigger instance, and
    # record an item as fired that has no session at all. That is #647's direction, and
    # it is the worse one.
    spawn_attempted = true
    session = trigger.create_session!(prompt: prompt)

    # Burst control suppressed the spawn: the trigger has exceeded its cap and is
    # spawning nothing until the burst subsides. Leave the item unseen so it fires
    # for real once the trigger is back under its cap (its label is still there —
    # the seen-set is state, so nothing is lost). This is expected behavior, not a
    # dropped wake, so log it at info rather than storming WARN per item per tick
    # for the whole burst.
    if session.nil? && trigger.last_fire_burst_suppressed?
      Rails.logger.info "[GithubTriggerPollerJob] Trigger #{trigger.id} is burst-suppressed for " \
                        "#{item_key(item)} (#{event}); leaving it unseen so it fires once the burst ends"
      return false
    end

    # Dedup suppressed the spawn: a session this trigger already spawned is still
    # pending and carries the same intent. Leave the item unseen — unlike a
    # broadcast event, a label or an open issue is durable state, so the item
    # fires for real on a later tick once that session is done. Info, not warn:
    # nothing was dropped and nothing is wrong.
    if session.nil? && trigger.last_fire_skipped_for_pending_session?
      Rails.logger.info "[GithubTriggerPollerJob] Trigger #{trigger.id} skipped #{item_key(item)} (#{event}) — " \
                        "session #{trigger.last_fire_pending_session.id} is still pending; leaving it unseen"
      return false
    end

    # create_session! returns the session truthily even when a reuse_session trigger DROPPED
    # the follow-up prompt (target session busy, enqueue_messages off). Treating that as a
    # fire would record the item as seen and consume the event without any work ever having
    # been done. AoEventTriggerJob and ScheduleTriggerJob guard the same way.
    if session.nil? || trigger.last_follow_up_dropped?
      Rails.logger.warn "[GithubTriggerPollerJob] Trigger #{trigger.id} dropped the follow-up for " \
                        "#{item_key(item)} (#{event}); leaving it unseen so the next tick retries"
      return false
    end

    Rails.logger.info "[GithubTriggerPollerJob] Created session #{session.id} for trigger " \
                      "#{trigger.id} from #{item_key(item)} (#{event})"
    true
  rescue => e
    # A raise is NOT proof that nothing was created. Session.create_from_agent_root!
    # commits the session row and then enqueues its one AgentSessionJob, and
    # Trigger#create_session! keeps going afterwards — the reuse pointer, the
    # sessions_created counter, the missed-fire clear. Anything from the enqueue
    # onward can raise over a live session row, and returning false here would
    # leave the item unseen and hand the next tick, sixty seconds later, an event
    # that already has a session.
    #
    # That is defect 1 of #704: trigger 352 spawned TWO merge-gate sessions for one
    # `ready to merge` label, 55s and 43s apart, on the one mechanism authorized to
    # merge without human sign-off — a double-merge race whenever both dispatch.
    #
    # So the question is not "did this method return cleanly" but "does a session
    # exist for this item", and Trigger#last_fire_created_session answers it. When
    # one does, the event is consumed: report the failure loudly, and treat the item
    # as fired so it is never spawned for twice.
    #
    # A session that was created but whose start job did not survive the failure is
    # defect 2 of the same issue, and it has its own owner: StalledStartSweepJob
    # restarts a `waiting` session with no job (#737). Re-firing here would not have
    # rescued it either — it would have spawned a sibling and left the original
    # stranded regardless, which is precisely what happened to session 10426.
    created = spawn_attempted ? trigger.last_fire_created_session : nil
    if created
      Rails.logger.error "[GithubTriggerPollerJob] Trigger #{trigger.id} created session " \
                         "#{created.id} for #{item_key(item)} (#{event}) but the fire then failed: " \
                         "#{e.message}. Treating the event as fired — the session exists, so " \
                         "re-firing would spawn a duplicate. If it never starts, StalledStartSweepJob owns it."
      return true
    end

    Rails.logger.error "[GithubTriggerPollerJob] Failed to create session for " \
                       "#{item_key(item)} (#{event}): #{e.message}"
    false
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

  def context_block(item, event:)
    <<~TEXT.strip
      ## GitHub #{pull_request?(item) ? 'pull request' : 'issue'} (#{event})

      - **Repository:** #{repo_of(item)}
      - **Number:** ##{item['number']}
      - **URL:** #{item['html_url']}
      - **Title:** #{item['title']}
      - **Author:** #{item.dig('user', 'login') || 'unknown'}
      - **Labels:** #{labels_for(item).presence&.join(', ') || '(none)'}

      ### Body

      #{body_of(item).presence || '(no description)'}
    TEXT
  end

  # ── Item helpers ────────────────────────────────────────────────────────────

  # The search API identifies an item's repo only by its API URL:
  # "https://api.github.com/repos/owner/name" -> "owner/name"
  def repo_of(item)
    item["repository_url"].to_s.split("/repos/").last.presence || "unknown/unknown"
  end

  def item_key(item)
    "#{repo_of(item)}##{item['number']}"
  end

  def labels_for(item)
    Array(item["labels"]).filter_map { |label| label["name"].presence }
  end

  def pull_request?(item)
    item["pull_request"].present?
  end

  def body_of(item)
    body = item["body"].to_s
    body.length > MAX_BODY_LENGTH ? "#{body[0, MAX_BODY_LENGTH]}\n\n…(truncated)" : body
  end
end
