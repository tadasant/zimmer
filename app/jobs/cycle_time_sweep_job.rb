# frozen_string_literal: true

# Converges the Cycle Time table: computes every settled hierarchy that has no
# row yet, or a row written by an older CycleTimes::Analyzer::VERSION.
#
# It is the backfill AND the safety net. On the first ticks after the feature
# deploys it works through the last LOOKBACK of archived roots, a time-boxed
# slice at a time, newest first; after that it only finds what the archive hook
# missed, and a tick costs one indexed query. Bumping VERSION re-runs the
# backfill with no other step. Nobody has to open a shell for any of it.
#
# LOOKBACK is bounded by Log::RETENTION: older timelines have lost the state and
# archive lines the analysis reads, so they would all come out ineligible.
class CycleTimeSweepJob < ApplicationJob
  include SingletonSweep

  queue_as :default

  LOOKBACK = 60.days
  BATCH = 200
  BUDGET = 1.minute

  def perform(budget: BUDGET)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + budget.to_f
    analyzed = 0

    candidates.each do |root|
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      CycleTimes::Analyzer.call(root)
      analyzed += 1
    rescue => e
      # One poison hierarchy must not stop the rest of the slice. It stays a
      # candidate and is retried every tick, so it is reported — at warning
      # and under one fingerprint, so a stuck root is visible without paging
      # every fifteen minutes.
      Rails.logger.warn("[CycleTimeSweep] root #{root.id}: #{e.class}: #{e.message}")
      ErrorReporter.report_exception(e, level: :warning, fingerprint: [ "cycle-time-sweep", e.class.name ],
                                        context: { source: "CycleTimeSweepJob", root_session_id: root.id })
    end

    analyzed
  end

  # Archived roots in the lookback with no current row, newest first. A root
  # whose hierarchy is still in flight stays a candidate — and costs one
  # hierarchy walk per tick — until its last session archives.
  def self.candidate_scope(now: Time.current)
    Session.where(parent_session_id: nil, status: Session.statuses[:archived])
           .where(archived_at: (now - LOOKBACK)..)
           .where("NOT COALESCE(sessions.metadata ? :fork, false)", fork: SessionStatusSummaryGenerator::FORK_MARKER)
           .where.not(
             id: CycleTimeAnalysis.where(algorithm_version: CycleTimes::Analyzer::VERSION).select(:root_session_id)
           )
  end

  private

  def candidates
    self.class.candidate_scope.order(archived_at: :desc).limit(BATCH).to_a
  end
end
