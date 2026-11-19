# frozen_string_literal: true

# The daily pass over operating costs that needs no secret.
#
# 1. Derives what Zimmer can see in its own ledgers (OperatingCosts::DerivedCollector)
#    and records it through the same write contract everything else uses, and
#    removes any derived figure in the window it no longer derives (a $0 for a
#    day whose usage turned out to be unpriced).
# 2. Rebuilds every account's daily series over the trailing year, so a
#    subscription keeps accruing on days nothing was reported.
# 3. Re-splits the current and previous month across agent roots and
#    functionalities. Older months keep the split they were given unless new
#    figures for them arrive.
# 4. Leaves one OperatingCostCollectionRun row, which is what the Costs page,
#    /health and `get_operating_costs` read to say whether this ran.
#
# Everything external (vendor bills, credit balances) arrives through
# `action_operating_costs` from the daily collection session; this job never
# calls a vendor.
#
# Idempotent: observations are upserted by their natural key and the rebuilt
# tables are replaced wholesale, so a second run the same day writes nothing new.
class OperatingCostsCollectionJob < ApplicationJob
  queue_as :maintenance
  include SingletonSweep

  REBUILD_DAYS = OperatingCosts::Recorder::REBUILD_HORIZON

  def perform
    run = OperatingCostCollectionRun.create!(collector: OperatingCostCollectionRun::DERIVED_COLLECTOR, status: "running",
                                             started_at: Time.current)
    today = Date.current
    collector = OperatingCosts::DerivedCollector.new(today: today)
    observations = collector.observations
    counts = observations.any? ? OperatingCosts::Recorder.record!({ "observations" => observations }, today: today, derived: true).counts : {}
    # Before the rebuild below, which is what takes a removed figure off the series.
    superseded = collector.superseded.delete_all

    accounts = OperatingCostAccount.all.to_a
    rows = accounts.sum { |account| OperatingCosts::Ledger.rebuild!(account: account, from: today - REBUILD_DAYS, to: today - 1) }
    [ (today - 1).beginning_of_month.prev_month, (today - 1).beginning_of_month ].each do |month|
      OperatingCosts::Allocator.allocate!(month: month, accounts: accounts)
    end

    run.update!(status: "succeeded", finished_at: Time.current, rows_written: observations.size,
                details: { derived_observations: observations.size, superseded_observations: superseded,
                           daily_entries: rows, accounts: accounts.size, counts: counts })
    run
  rescue StandardError => e
    # Recorded on the run (the Costs page and /health read it) and reported, so
    # error tracking sees it too; not re-raised, since tomorrow's run converges.
    Rails.error.report(e, handled: true, context: { job: self.class.name })
    run&.update!(status: "failed", finished_at: Time.current, error: "#{e.class}: #{e.message}".truncate(1_000))
    Rails.logger.warn("[OperatingCostsCollectionJob] #{e.class}: #{e.message}")
    run
  end
end
