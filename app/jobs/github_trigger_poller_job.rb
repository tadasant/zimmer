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

  def perform
    AlertBatcher.with_batch do
      TriggerCondition.github
        .joins(:trigger)
        .where(triggers: { status: "enabled" })
        .includes(:trigger)
        .find_each do |condition|
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
    items = GithubSearchService.search_issues(label_query(condition))

    # One key per (item, label). Watching two labels and having both added is two
    # distinct "the label was added" events; keying by item alone would swallow the
    # second one forever, since the item would already be in the seen-set.
    watched = condition.github_labels.to_set
    candidates = {}
    items.each do |item|
      labels_for(item).each do |label|
        candidates["#{item_key(item)}:#{label}"] = [ item, label ] if watched.include?(label)
      end
    end
    current_keys = candidates.keys.to_set

    unless condition.github_baselined?
      condition.write_github_state!("seen_items" => current_keys.to_a.sort)
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
    condition.write_github_state!("seen_items" => (retained + fired).to_a.sort)
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
    cursor = condition.github_last_issue_at

    # First tick: start the clock. Issues that predate the condition are history, not
    # events this trigger was created to react to.
    if cursor.blank?
      now = Time.current.utc.iso8601
      condition.write_github_state!("last_issue_at" => now, "seen_issue_keys" => [])
      Rails.logger.info "[GithubTriggerPollerJob] Baselined condition #{condition.id} at #{now}; firing none"
      return
    end

    query = [
      "is:issue",
      GithubSearchService.repo_group(condition.github_repos),
      "created:>=#{cursor}"
    ].join(" ")

    # Ascending, so the cursor can advance through the batch and stop cleanly at the
    # first item that fails to produce a session.
    items = GithubSearchService.search_issues(query, sort: "created", order: "asc")
    return if items.empty?

    already_fired = condition.github_seen_issue_keys.to_set
    fresh = items.reject { |item| already_fired.include?(item_key(item)) }
    return if fresh.empty?

    newest = nil
    fired_keys = already_fired.dup

    fresh.each do |item|
      break unless fire(condition, item, event: "issue opened")

      newest = item
      fired_keys << item_key(item)
    end

    # Nothing fired: leave the cursor where it is so the whole batch is retried. This is
    # also what absorbs GitHub's search-index lag — an issue not yet indexed simply
    # arrives on a later tick, because the cursor never moved past it.
    return if newest.nil?

    new_cursor = newest["created_at"]

    # Everything already fired that shares the new cursor's second must be remembered:
    # the inclusive `created:>=` re-queries that second on the next tick.
    seen_at_cursor = items
      .select { |item| item["created_at"] == new_cursor && fired_keys.include?(item_key(item)) }
      .map { |item| item_key(item) }
      .uniq
      .sort

    condition.write_github_state!(
      "last_issue_at" => new_cursor,
      "seen_issue_keys" => seen_at_cursor
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
    condition.update!(last_triggered_at: Time.current)

    Rails.logger.info "[GithubTriggerPollerJob] Created session #{session&.id} for trigger " \
                      "#{trigger.id} from #{item_key(item)} (#{event})"
    true
  rescue => e
    Rails.logger.error "[GithubTriggerPollerJob] Failed to create session for " \
                       "#{item_key(item)} (#{event}): #{e.message}"
    false
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
