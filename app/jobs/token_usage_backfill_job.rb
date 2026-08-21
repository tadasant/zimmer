# frozen_string_literal: true

# Gets history into the token-spend ledger without anyone opening a shell on the
# production box.
#
# TokenUsageIngestionJob only looks at files modified in the last two hours, so
# everything older than the day ingestion shipped has to be swept once. That
# sweep was a rake task, which made a deploy insufficient: the numbers on the
# Costs page stayed wrong until a human SSH'd in. This job is the fix. On the
# first tick after a deploy it starts a TokenUsageBackfill run, works it two
# minutes at a time, and — once the corpus is covered — costs one indexed lookup
# per tick forever after.
#
# Safe to run repeatedly by construction: ingestion upserts on `request_id`, so a
# re-swept directory writes nothing. A slice that dies mid-chunk loses at most
# that chunk's progress, because the cursor only advances on a committed chunk.
#
# QUEUE PLACEMENT — `default`, deliberately not `pollers`. This is bulk work that
# holds its thread for minutes, and `pollers` has three threads shared by every
# latency-sensitive singleton poller (Slack, GitHub, the health probes). Parking
# a multi-minute scan there would delay trigger firing for as long as the
# backfill lasts. `default` is where the periodic bulk work already lives.
class TokenUsageBackfillJob < ApplicationJob
  queue_as :default

  # How long one slice may hold its worker thread. Well under the five-minute
  # cron so a slice is finished and the thread returned before the next tick.
  SLICE_BUDGET = 2.minutes

  # One sweep at a time. Two would walk the same directories and contend on the
  # same unique index for no benefit.
  good_job_control_concurrency_with(
    key: -> { "token_usage_backfill" },
    total_limit: 1
  )

  def perform(budget: SLICE_BUDGET)
    run = TokenUsageBackfill.pending

    # Nothing pending and nothing ever finished means this deployment has never
    # been backfilled — the first tick after the feature deploys, and the only
    # place a run is created without anyone asking for one.
    run ||= TokenUsageBackfill.request!(trigger: "automatic") unless TokenUsageBackfill.ever_completed?

    return nil if run.nil?

    TokenUsageBackfillService.new(run: run, budget: budget).call
  end
end
