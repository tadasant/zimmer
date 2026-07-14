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
# - **A skipped tick is harmless.** The seen-set is state, not a cursor: a missed run
#   changes nothing, because the next run still sees the label and still fires.
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

  def perform
    conditions = TriggerCondition.github
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .includes(:trigger)

    # Nothing to poll — don't spend a `gh auth status` subprocess every minute on the
    # (common) instance that has no GitHub triggers at all.
    return unless conditions.exists?

    # Degrade gracefully when the environment has no GitHub credential, exactly as
    # SlackTriggerPollerJob returns early on an unconfigured Slack. Without this, an
    # environment whose worker lacks `gh auth` (e.g. staging) shells out once per
    # condition every tick, each call failing with "please run: gh auth login", and the
    # per-condition rescue below turns every one into an alert — an every-minute storm
    # over a missing credential. One WARN per tick is enough to make the gap visible.
    unless GithubSearchService.configured?
      Rails.logger.warn "[GithubTriggerPollerJob] gh CLI is not authenticated " \
                        "(no gh auth login / GH_TOKEN); skipping GitHub trigger polling this tick"
      return
    end

    AlertBatcher.with_batch do
      conditions.find_each do |condition|
        process_condition(condition)
      rescue => e
        Rails.logger.error "[GithubTriggerPollerJob] Error processing condition #{condition.id}: #{e.message}"
        AlertService.raise_alert(
          "GitHub trigger poller error",
          details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' " \
                   "(ID: #{condition.trigger_id}) failed:\n#{e.message}",
          source: "GithubTriggerPollerJob",
          dedup_key: "github_trigger_condition_#{condition.id}"
        )
      end
    end
  end

  private

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
      write_state(condition, scope, { "seen_items" => current_keys.to_a.sort })
      Rails.logger.info "[GithubTriggerPollerJob] Baselined condition #{condition.id} " \
                        "with #{current_keys.size} already-labelled item(s); firing none"
      return
    end

    seen = condition.github_seen_items.to_set

    # Keys we already knew about AND that still carry the label. Anything that lost its
    # label is deliberately dropped here, which is what lets a re-label fire again.
    retained = current_keys & seen
    fired = Set.new

    (current_keys - seen).sort.each do |key|
      item, label = candidates[key]
      fired << key if fire(condition, item, event: "label added: #{label}")
    end

    # Keys that failed to produce a session are in neither set, so the next tick sees
    # them as new again and retries.
    write_state(condition, scope, { "seen_items" => (retained + fired).to_a.sort }, fired: fired.any?)
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

    query = [
      "is:issue",
      GithubSearchService.repo_group(condition.github_repos),
      "created:>=#{window_start}"
    ].join(" ")

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

    session = trigger.create_session!(prompt: prompt)

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
