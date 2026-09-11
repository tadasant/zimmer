# frozen_string_literal: true

# The searches a GitHub trigger condition is polled with, and how the items they return
# are read — shared by GithubTriggerPollerJob, which polls, and GithubTriggerHealthCheckJob,
# which asks the same searches whether the poller has kept up.
#
# Shared rather than duplicated because the freshness check is only meaningful if it asks
# GitHub the SAME question the poller does: a probe built from its own query would report
# a difference between two queries as a stalled poller. Everything here is derived from
# the condition's configuration and the search API's item shape; nothing here holds state.
module GithubTriggerSearch
  extend ActiveSupport::Concern

  private

  # ── Queries ─────────────────────────────────────────────────────────────────

  # A github_label condition's search: every OPEN item in its repos carrying one of its
  # labels. No time bound — the seen-set is state, and every tick re-derives the whole set.
  def label_query(condition)
    [
      "is:open",
      condition.github_pull_requests? ? "is:pr" : "is:issue",
      GithubSearchService.repo_group(condition.github_repos),
      GithubSearchService.label_group(condition.github_labels)
    ].join(" ")
  end

  # A github_issue condition's search: issues in its repos, minus the excluded labels,
  # created at or after +window_start+ — or with no time bound at all when it is nil,
  # which is the freshness probe's "what is the newest issue there is?".
  #
  # The exclusion is applied by the SEARCH, not by filtering what comes back, so an
  # excluded issue never enters the tick at all: it is not fired, and — because the
  # cursor only ever advances past issues that fired — it does not drag the cursor
  # forward either. An issue held back this way is simply never an event.
  #
  # The consequence worth knowing is that the label has to be there when GitHub indexes
  # the issue, which in practice means at creation (`gh issue create --label …`). The
  # poller ticks every minute, so a label added a minute later can lose the race.
  def issue_query(condition, window_start = nil)
    [
      "is:issue",
      GithubSearchService.repo_group(condition.github_repos),
      ("created:>=#{window_start}" if window_start.present?),
      GithubSearchService.exclude_label_terms(condition.github_exclude_labels)
    ].reject(&:blank?).join(" ")
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

  # Whether this issue was opened before its repo joined the condition's scope. Keyed on
  # `created_at`, which never changes, so an issue GitHub indexes long after the baseline
  # is still judged by when it was OPENED — the property the baseline is a statement about.
  def predates_repo_baseline?(item, baselines)
    baseline = baselines[repo_of(item).to_s.downcase]

    baseline.present? && item["created_at"].to_s < baseline.to_s
  end
end
