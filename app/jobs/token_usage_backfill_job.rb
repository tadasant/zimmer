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
# EVERY RUNTIME, not just Claude Code. The sliced, cursored machinery below is
# Claude-shaped — it walks a filesystem corpus by directory — but "re-scan
# history" is a request about the LEDGER, and a ledger with two runtimes in it
# has to answer it for all of them or the button quietly means less than it says.
# Pi's whole corpus is a table and Codex's is a few thousand rollout files, so
# each is swept in one pass on a run's first slice; see #sweep_other_runtimes.
#
# QUEUE PLACEMENT — `default`, deliberately not `pollers`. This is bulk work that
# holds its thread for minutes, and `pollers` has three threads shared by every
# latency-sensitive singleton poller (Slack, GitHub, the health probes). Parking
# a multi-minute scan there would delay trigger firing for as long as the
# backfill lasts. `default` is where the periodic bulk work already lives.
class TokenUsageBackfillJob < ApplicationJob
  queue_as :maintenance

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

    sweep_other_runtimes if run.started_at.nil?

    TokenUsageBackfillService.new(run: run, budget: budget).call
  end

  private

  # Every non-Claude runtime's whole history, once per requested run.
  #
  # Gated on `started_at` — which TokenUsageBackfillService sets on its first
  # slice — so this happens once at the head of a run rather than on each of its
  # two-minute ticks. A slice that dies before that write simply does it again
  # next tick, which costs time and nothing else.
  #
  # This is what makes the ledger's history RE-ENTRANT for those runtimes. The
  # post-deploy tasks that shipped Pi's and Codex's ingestors cover history once
  # and are terminal by design, and the recurring job only ever looks two hours back — so
  # without this, any gap longer than that window (a worker outage, an ingestor
  # bug found a day later) would lose that spend permanently, with no surface to
  # ask for it back. Now the Costs page button, `POST /api/v1/costs/backfill` and
  # `action_health`'s `backfill_token_usage` all recover it.
  #
  # `modified_since: nil` is the whole point: the corpus, not a window.
  def sweep_other_runtimes
    RuntimeRegistry.usage_ingestor_classes.each do |ingestor|
      next if ingestor == TokenUsageIngestionService

      result = ingestor.new(modified_since: nil).call
      Rails.logger.info("[TokenUsageBackfillJob] #{ingestor.name}: #{result}")
    rescue GoodJob::InterruptError, ActiveRecord::StatementTimeout
      raise
    rescue StandardError => e
      # Never at the cost of the Claude sweep this job exists for. Logged at
      # `error` because that is what reaches a human.
      Rails.logger.error("[TokenUsageBackfillJob] #{ingestor.name} failed: #{e.class}: #{e.message}")
    end
  end
end
