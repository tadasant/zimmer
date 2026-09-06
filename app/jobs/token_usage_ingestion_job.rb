# frozen_string_literal: true

# Sweeps recent transcripts into the token-usage tables, once per runtime that
# has an ingestor.
#
# Runs on a cron. It only looks at transcripts touched inside a lookback window,
# so a steady-state run is cheap: the Claude corpus is thousands of files and
# tens of gigabytes, and re-reading all of it every few minutes to find a few
# hundred new API calls would cost more than it measures. The full Claude corpus
# is covered once by TokenUsageBackfillJob; the full Pi corpus by the one-time
# post-deploy task that shipped its ingestor.
#
# The lookback deliberately overlaps the cron interval by a wide margin. Ingestion
# is idempotent on `request_id`, so overlap costs nothing and closes the gap left
# by a missed run, a deploy, or a session whose transcript is written late.
#
# WHICH INGESTORS RUN IS READ OFF THE RUNTIME REGISTRY, not listed here. Where a
# runtime records what it spent is a property of the runtime — a host-global tree
# for Claude Code, the clone (and so `sessions.transcript`) for Pi — and
# RuntimeRegistry::Bundle is where per-runtime facts live. A runtime whose slot is
# nil is one whose spend is not ingested yet, and it is nil in one legible place.
class TokenUsageIngestionJob < ApplicationJob
  queue_as :pollers

  LOOKBACK = 2.hours

  # One sweep at a time. Two concurrent scans would do the same work twice and
  # contend on the same unique index for no benefit.
  good_job_control_concurrency_with(
    key: -> { "token_usage_ingestion" },
    total_limit: 1
  )

  # @return [Array] one result per ingestor that ran, in registry order
  def perform(modified_since: nil)
    since = modified_since || LOOKBACK.ago

    RuntimeRegistry.usage_ingestor_classes.filter_map do |ingestor|
      # One ingestor failing must not cost the others their sweep. They read
      # different corpora and share nothing but the table they write to, and
      # Claude Code is upwards of 99% of this deployment's spend — letting a
      # runtime with three sessions in it take that sweep down with it would be
      # the wrong trade. Caught rather than raised, but not swallowed: a `.error`
      # line is what the error-log alert pages on, so the failure reaches a human
      # in the same breath as the other runtimes' rows reach the ledger.
      result = ingestor.new(modified_since: since).call
      Rails.logger.info("[TokenUsageIngestionJob] #{result}")
      result
    rescue StandardError => e
      Rails.logger.error("[TokenUsageIngestionJob] #{ingestor.name} failed: #{e.class}: #{e.message}")
      nil
    end
  end
end
