# frozen_string_literal: true

# Sweeps recent transcripts into the token-usage tables.
#
# Runs on a cron. It only looks at files modified inside a lookback window, so a
# steady-state run is cheap: the corpus is thousands of files and tens of
# gigabytes, and re-reading all of it every few minutes to find a few hundred new
# API calls would cost more than it measures. The full corpus is covered once, by
# `rake token_usage:backfill`.
#
# The lookback deliberately overlaps the cron interval by a wide margin. Ingestion
# is idempotent on `request_id`, so overlap costs nothing and closes the gap left
# by a missed run, a deploy, or a session whose transcript is written late.
class TokenUsageIngestionJob < ApplicationJob
  queue_as :pollers

  LOOKBACK = 2.hours

  # One sweep at a time. Two concurrent scans would do the same work twice and
  # contend on the same unique index for no benefit.
  good_job_control_concurrency_with(
    key: -> { "token_usage_ingestion" },
    total_limit: 1
  )

  def perform(modified_since: nil)
    result = TokenUsageIngestionService.new(
      modified_since: modified_since || LOOKBACK.ago
    ).call

    Rails.logger.info("[TokenUsageIngestionJob] #{result}")
    result
  end
end
