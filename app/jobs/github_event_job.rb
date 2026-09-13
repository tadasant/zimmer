# frozen_string_literal: true

# Fires `github_issue` triggers from one GitHub `issues.opened` webhook delivery.
#
# Webhooks::GithubController verifies the delivery, records it under its `X-GitHub-Delivery` id and
# enqueues this with the issue. From here on it is GithubTriggerPollerJob with detection swapped
# out: the same conditions, the same item predicates (GithubTriggerSearch), the same prompt and
# spawn (GithubTriggerFiring#fire).
#
# Which conditions it serves: every `github_issue` condition on an enabled trigger
# (Webhooks::Source.github#served_conditions). `github_label` conditions stay on the poller in
# every mode.
#
# What it does not do is move a condition's cursor or its seen keys. In
# `webhook_with_poll_fallback` the poller owns them. It finds the issue a minute later, loses the
# claim this fire took, and records the issue as fired then — so the cursor stays the poller's
# statement of what it has seen, and an issue the webhook never received is still in the poller's
# window when it looks.
class GithubEventJob < ApplicationJob
  include GithubTriggerFiring

  # Latency-sensitive trigger firing, the lane SlackEventJob shares.
  queue_as :triggers

  EVENT = "issue opened"

  # What is kept of a delivery's issue: the fields a search-API item carries that the poller reads,
  # and nothing else. `repository_url` is the one the poller derives the repository from.
  ITEM_FIELDS = %w[number title body html_url repository_url created_at].freeze

  # The issue in the shape GithubTriggerSearch reads a search-API item in.
  def self.item_arguments(issue)
    item = issue.slice(*ITEM_FIELDS)
    item["user"] = { "login" => issue.dig("user", "login").to_s } if issue.dig("user", "login").present?
    item["labels"] = Array(issue["labels"]).filter_map { |label| { "name" => label["name"].to_s } if label.is_a?(Hash) && label["name"].present? }
    item["pull_request"] = { "url" => issue.dig("pull_request", "url").to_s } if issue["pull_request"].present?
    item
  end

  def perform(delivery_id, item)
    # Switched back to `poll` between accepting this and running it: the poller owns every issue
    # again and claims none of them, so firing here could double-fire.
    return unless Webhooks::Source.github.webhook_enabled?
    return unless item.is_a?(Hash) && item["number"].present? && item["repository_url"].present?

    served_conditions.each do |condition|
      next unless webhook_match?(condition, item)

      fire(condition, item, event: EVENT, via: "webhook")
    rescue => e
      # WARN, not ERROR: a fire that raised took its claim down with its transaction, so the poller
      # still owns this issue and fires it on its next tick.
      Rails.logger.warn "[GithubEventJob] Could not fire condition #{condition.id} for GitHub delivery #{delivery_id} " \
                        "(#{item_key(item)}): #{e.class}: #{e.message} — leaving it to the poller"
      ErrorReporter.report_exception(
        e,
        level: :warning,
        context: {
          title: "GitHub webhook trigger fire failed",
          source: "GithubEventJob",
          details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' (ID: #{condition.trigger_id}) " \
                   "failed on GitHub delivery #{delivery_id}. The poller is the backstop for this issue.",
          condition_id: condition.id,
          trigger_id: condition.trigger_id
        }
      )
    end
  end

  private

  def served_conditions
    Webhooks::Source.github.served_conditions
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .includes(:trigger)
  end

  # Whether GithubTriggerPollerJob#process_new_issue_condition would fire +condition+ for +item+ if
  # its search had returned it. Each clause names the part of the poller it mirrors.
  def webhook_match?(condition, item)
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

    # The `-label:` terms in #issue_query, which also ignore case.
    excluded = condition.github_exclude_labels
    labels_for(item).none? { |label| excluded.any? { |exclude| exclude.casecmp?(label) } }
  end
end
