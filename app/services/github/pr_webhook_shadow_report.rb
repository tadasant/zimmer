# frozen_string_literal: true

module Github
  # Whether GitHub's webhook announced the PR changes the per-session pollers found, over a window:
  # the evidence for moving GITHUB_PR_INGEST_MODE from `webhook_shadow` to
  # `webhook_with_poll_fallback`. Reads GithubPrShadowObservation, which
  # Github::PrWebhookIngest.observe writes once per change a poll found on a covered session.
  #
  # Per kind (status, ci, comments, merge_conflict):
  #
  #   hit       the webhook signalled the change before the poll found it. `lead` is how far ahead
  #             it was: the poll's time minus the newest signal's (a lower bound after a burst).
  #   miss      the poll found the change and no signal had announced it: a hook missing an event
  #             type, a dropped delivery, or a change no delivery names.
  #
  # Unlike the trigger comparison (Webhooks::GithubShadowComparison) there is no `pending`: each
  # row is written once, by the poll, already knowing whether a signal came first.
  #
  # Read by `compare_github_pr_webhook_shadow`.
  class PrWebhookShadowReport
    WINDOW = 24.hours
    DEFAULT_RECENT = 30
    MAX_RECENT = 200

    def self.report(**options)
      new(**options).report
    end

    # +kind+ and +mode+ narrow to one kind or one ingest mode. +visible+ decides which session ids
    # the caller may see, for a restricted MCP connection (called with the ids in the window,
    # returns the visible ones); everything when nil.
    def initialize(now: Time.current, since: nil, kind: nil, mode: nil, visible: nil, recent: DEFAULT_RECENT)
      @now = now
      @since = since || (now - WINDOW)
      @kind = kind
      @mode = mode
      @visible = visible
      @recent = recent.to_i.clamp(0, MAX_RECENT)
    end

    def report
      rows = observations
      by_kind = rows.group_by { |row| row[:kind] }

      {
        mode: PrWebhookIngest.source.mode,
        since: @since,
        window_seconds: (@now - @since).round,
        totals: counts(rows),
        lead: lead(rows),
        kinds: (@kind ? [ @kind ] : GithubPrShadowObservation::KINDS).map do |kind|
          kind_rows = by_kind.fetch(kind, [])
          { kind: kind, **counts(kind_rows), lead: lead(kind_rows) }
        end,
        modes: rows.map { |row| row[:mode] }.tally,
        recent_misses: rows.reject { |row| row[:hit] }.last(@recent).reverse.map { |row| present(row) }
      }
    end

    private

    def observations
      scope = GithubPrShadowObservation.where(created_at: @since..@now)
      scope = scope.where(kind: @kind) if @kind
      scope = scope.where(mode: @mode) if @mode
      scope = scope.where(session_id: @visible.call(scope.distinct.pluck(:session_id))) if @visible
      scope.order(:created_at, :id)
        .pluck(:session_id, :pr_url, :kind, :mode, :hit, :signaled_at, :created_at)
        .map do |session_id, pr_url, kind, mode, hit, signaled_at, at|
          { session_id: session_id, pr_url: pr_url, kind: kind, mode: mode, hit: hit, signaled_at: signaled_at, observed_at: at }
        end
    end

    def counts(rows)
      hits = rows.count { |row| row[:hit] }
      misses = rows.size - hits
      { hit: hits, miss: misses, hit_rate: rows.empty? ? nil : (hits.to_f / rows.size).round(3) }
    end

    # Seconds the webhook was ahead of the poll, over hits.
    def lead(rows)
      samples = rows.filter_map { |row| (row[:observed_at] - row[:signaled_at]).round if row[:hit] && row[:signaled_at] }.sort
      return { samples: 0, median_seconds: nil, p90_seconds: nil, max_seconds: nil } if samples.empty?

      { samples: samples.size, median_seconds: percentile(samples, 0.5), p90_seconds: percentile(samples, 0.9), max_seconds: samples.last }
    end

    # Nearest-rank, so the answer is always an observed value.
    def percentile(sorted, fraction)
      sorted[((sorted.size * fraction).ceil - 1).clamp(0, sorted.size - 1)]
    end

    def present(row)
      {
        session_id: row[:session_id],
        pr_url: row[:pr_url],
        kind: row[:kind],
        mode: row[:mode],
        observed_at: row[:observed_at].iso8601
      }
    end
  end
end
