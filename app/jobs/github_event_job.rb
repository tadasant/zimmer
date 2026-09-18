# frozen_string_literal: true

# Fires GitHub triggers from one webhook delivery.
#
# Webhooks::GithubController verifies the delivery, records it under its `X-GitHub-Delivery` id and
# enqueues this with the item it carries. From here on it is GithubTriggerPollerJob with detection
# swapped out: the same conditions, the same item predicates (GithubTriggerSearch), the same prompt
# and spawn (GithubTriggerFiring#fire).
#
# Which conditions each delivery serves:
#
# | Delivery | Conditions |
# | --- | --- |
# | `issues.opened` | `github_issue`, and `github_label` for an issue opened carrying a watched label |
# | `issues.reopened`, `pull_request.opened`, `pull_request.reopened` | `github_label` — the item re-enters the poller's `is:open` search carrying its labels |
# | `issues.labeled`, `pull_request.labeled` | `github_label`, for the one label that was added |
#
# `github_issue` conditions fire from `issues.opened` alone: their state is a `created_at` cursor,
# and nothing but opening an issue creates one.
#
# What this does not do is move a condition's cursor or its seen keys. In
# `webhook_with_poll_fallback` the poller owns them. It finds the item a minute later, loses the
# claim this fire took, and records the item then — so the poller's state stays the poller's
# statement of what it has seen, and an event the webhook never received is still there when the
# poller looks.
class GithubEventJob < ApplicationJob
  include GithubTriggerFiring

  # Latency-sensitive trigger firing, the lane SlackEventJob shares.
  queue_as :triggers

  # The arguments carry an issue's title and body. ActiveJob would print them on the INFO lines
  # it writes when this is enqueued and performed, which is the text Webhooks::BaseController
  # keeps out of the logs.
  self.log_arguments = false

  ISSUE_OPENED = "issues.opened"
  ISSUE_EVENT = "issue opened"

  # Deliveries that can put an item into a `github_label` condition's search result set: a label
  # added to an open item, or an item becoming open while carrying one. `github_label` keys an
  # event as (item, label), so both halves of that pair have to be able to change.
  LABEL_EVENTS = %w[
    issues.opened issues.reopened issues.labeled
    pull_request.opened pull_request.reopened pull_request.labeled
  ].freeze

  # What is kept of a delivery's item: the fields a search-API item carries that the poller reads,
  # and nothing else. `repository_url` is the one the poller derives the repository from, and
  # `state` is the poller's `is:open`.
  ITEM_FIELDS = %w[number title body html_url repository_url created_at state].freeze

  # The item in the shape GithubTriggerSearch reads a search-API item in.
  #
  # +object+ is the delivery's `issue` or `pull_request`. A `pull_request` object carries no
  # `repository_url` — the search API's only statement of which repo an item is in — so it is
  # rebuilt from the delivery's own `repository`, and `pull_request` is stamped on so
  # GithubTriggerSearch#pull_request? reads the item as one, exactly as the search's own
  # sub-object makes it.
  #
  # The body is cut one character past MAX_BODY_LENGTH: enough for #body_of and #context_block to
  # see that it was longer and add their truncation marker, without storing up to a megabyte of it
  # in the job's arguments.
  def self.item_arguments(object, repository: nil, pull_request: false)
    item = object.slice(*ITEM_FIELDS)
    item["repository_url"] = repository_url_for(object, repository)
    item["body"] = item["body"][0, MAX_BODY_LENGTH + 1] if item["body"].is_a?(String)

    user = object["user"]
    item["user"] = { "login" => user["login"].to_s } if user.is_a?(Hash) && user["login"].present?
    item["labels"] = Array(object["labels"]).filter_map { |label| { "name" => label["name"].to_s } if label.is_a?(Hash) && label["name"].present? }
    delivered_pull_request = object["pull_request"]
    if pull_request
      item["pull_request"] = { "url" => object["html_url"].to_s }
    elsif delivered_pull_request.present?
      item["pull_request"] = { "url" => (delivered_pull_request.is_a?(Hash) ? delivered_pull_request["url"] : delivered_pull_request).to_s }
    end
    item.compact
  end

  # "https://api.github.com/repos/owner/name", from whichever half of the delivery carries it.
  def self.repository_url_for(object, repository)
    delivered = object["repository_url"]
    return delivered if delivered.is_a?(String) && delivered.present?

    full_name = repository.is_a?(Hash) ? repository["full_name"].to_s : ""
    "https://api.github.com/repos/#{full_name}" if full_name.present?
  end

  # +event+ is the delivery's "<event>.<action>"; +label+ the name of the label a `labeled`
  # delivery added, and nil for every other event.
  #
  # The arguments are shape-checked rather than trusted, and +item+ has a default, so a job already
  # in the queue when a release changes what this takes fails SOFT: it fires nothing and says so,
  # instead of raising an ArgumentError that pages. The poller is the backstop for whatever such a
  # job was carrying, so a dropped delivery costs latency and nothing else.
  def perform(delivery_id, event, item = nil, label = nil)
    # Switched back to `poll` between accepting this and running it: the poller owns every event
    # again and claims none of them, so firing here could double-fire.
    return unless Webhooks::Source.github.webhook_enabled?

    unless event.is_a?(String) && item.is_a?(Hash)
      Rails.logger.warn "[GithubEventJob] GitHub delivery #{delivery_id} arrived with arguments this release " \
                        "does not read (#{event.class}, #{item.class}); firing nothing and leaving it to the poller"
      return
    end

    return unless item["number"].present? && item["repository_url"].present?

    fire_issue_conditions(delivery_id, item) if event == ISSUE_OPENED
    fire_label_conditions(delivery_id, event, item, label) if LABEL_EVENTS.include?(event)
  end

  private

  def fire_issue_conditions(delivery_id, item)
    each_condition(delivery_id, "github_issue", item) do |condition|
      next unless issue_match?(condition, item)

      fire(condition, item, event: ISSUE_EVENT, via: "webhook")
    end
  end

  # A `labeled` delivery names the one label that was just added. An `opened`/`reopened` one names
  # none: what changed is that the item entered the poller's `is:open` search, so every label it
  # carries is a key that search would now return.
  def fire_label_conditions(delivery_id, event, item, label)
    names = event.end_with?(".labeled") ? [ label.to_s ].select(&:present?) : labels_for(item)
    return if names.empty?

    each_condition(delivery_id, "github_label", item) do |condition|
      label_matches(condition, item, names).each do |configured|
        # The same event string the poller writes for the same key, so a session a delivery fired
        # reads identically to one a poll fired.
        fire(condition, item, event: "label added: #{configured}", via: "webhook", label: configured)
      end
    end
  end

  def each_condition(delivery_id, condition_type, item)
    served_conditions(condition_type).each do |condition|
      yield condition
    rescue => e
      # #fire rescues its own spawn failures, so what reaches here failed before any fire began —
      # reading the condition or matching the item. No claim was taken, so the poller still owns
      # the event and fires it on its next tick: WARN, not ERROR.
      Rails.logger.warn "[GithubEventJob] Could not match condition #{condition.id} for GitHub delivery #{delivery_id} " \
                        "(#{item_key(item)}): #{e.class}: #{e.message} — leaving it to the poller"
      ErrorReporter.report_exception(
        e,
        level: :warning,
        context: {
          title: "GitHub webhook trigger fire failed",
          source: "GithubEventJob",
          details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' (ID: #{condition.trigger_id}) " \
                   "failed on GitHub delivery #{delivery_id}. The poller is the backstop for this event.",
          condition_id: condition.id,
          trigger_id: condition.trigger_id
        }
      )
    end
  end

  def served_conditions(condition_type)
    Webhooks::Source.github.served_conditions
      .where(condition_type: condition_type)
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .includes(:trigger)
  end

  # Whether GithubTriggerPollerJob#process_new_issue_condition would fire +condition+ for +item+ if
  # its search had returned it. Each clause names the part of the poller it mirrors.
  def issue_match?(condition, item)
    # `is:issue` in #issue_query.
    return false if pull_request?(item)

    # The repo group in #issue_query. `repo:` qualifiers ignore case.
    return false unless condition.github_repos.any? { |repo| repo.casecmp?(repo_of(item)) }

    # A never-polled condition is baselined by its first tick, which fires nothing.
    cursor = condition.github_last_issue_at
    return false if cursor.blank?

    # `created:>=` the window the poller queries, INDEX_LAG_GRACE behind its cursor. An issue opened
    # before that — a transferred one keeps its original creation time — is not in any window the
    # poller will search.
    window_start = (Time.iso8601(cursor) - GithubTriggerPollerJob::INDEX_LAG_GRACE).utc.iso8601
    return false if item["created_at"].to_s < window_start

    # The two rejections in #process_new_issue_condition.
    return false if condition.github_seen_issue_keys.include?(item_key(item))
    return false if predates_repo_baseline?(item, condition.github_issue_repo_baselines)

    # The `-label:` terms in #issue_query, asked for exactly as GithubSearchService.exclude_label_terms
    # asks for them — see #searched_label.
    excluded = condition.github_exclude_labels.map { |label| searched_label(label) }
    labels_for(item).none? { |label| excluded.include?(label.to_s.downcase) }
  end

  # Which of +names+ GithubTriggerPollerJob#process_label_condition would fire +condition+ for if
  # its search had returned +item+ — as the CONFIGURED spelling of each, because that is the casing
  # the poller's seen-set and this claim's key are written in. Each clause names the part of the
  # poller it mirrors.
  def label_matches(condition, item, names)
    # `is:open` in #label_query. A label added to a closed item is not in the poller's result set,
    # and the poller has no way to learn of it later either — it is simply not an event.
    return [] unless item["state"].to_s == "open"

    # `is:pr` / `is:issue` in #label_query. A condition watches one or the other, never both.
    return [] unless condition.github_pull_requests? == pull_request?(item)

    # The repo group in #label_query. `repo:` qualifiers ignore case.
    return [] unless condition.github_repos.any? { |repo| repo.casecmp?(repo_of(item)) }

    # An un-baselined condition is baselined by its first tick, which fires nothing; a retargeted
    # one is re-baselined by its next tick, for the same reason. Both are #baseline_everything.
    return [] unless condition.github_baselined?
    return [] if condition.github_baseline_retargeted?

    # The `label:` group in #label_query, asked for exactly as GithubSearchService.label_group asks
    # for it — see #searched_label. The value is the CONFIGURED spelling, because that is what the
    # poller's seen-set and the claim key are written in.
    watched = condition.github_labels.index_by { |label| searched_label(label) }
    seen = condition.github_seen_items.map { |key| key.to_s.downcase }.to_set

    names.filter_map do |name|
      configured = watched[name.to_s.downcase]
      next if configured.nil?

      # `current_keys - seen` in #process_label_condition. A key the poller already holds is not a
      # new event — which includes one whose removal is still inside REMOVAL_GRACE_TICKS, where
      # the poller does not fire a re-add either. Compared case-insensitively like every clause
      # around it: the two paths read the repository's casing from different fields, and the
      # direction this would fail in is a duplicate session.
      next if seen.include?("#{item_key(item)}:#{configured}".downcase)

      # The `absorbed` branch: a repo or label the baseline does not cover is having its first
      # tick, and what it already carries is state rather than an event.
      next unless condition.github_baseline_covers?(repo_of(item), configured)

      configured
    end.uniq
  end
end
