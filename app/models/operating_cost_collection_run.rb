# frozen_string_literal: true

# "Has it run, and what did it cover": one row per collection, whether the daily
# job's derived pass or a session writing through `action_operating_costs`.
class OperatingCostCollectionRun < ApplicationRecord
  STATUSES = %w[running succeeded failed].freeze
  DERIVED_COLLECTOR = "derived"
  # How old the newest successful run of a collector may be before the Costs
  # page and /health call it stale.
  STALE_AFTER = 36.hours

  validates :collector, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :started_at, presence: true

  scope :recent, -> { order(started_at: :desc) }
  scope :succeeded, -> { where(status: "succeeded") }

  # The newest run per collector.
  def self.latest_by_collector
    where(id: select("DISTINCT ON (collector) id").order(:collector, started_at: :desc)).order(:collector)
  end

  def as_api_json
    { id: id, collector: collector, status: status, started_at: started_at, finished_at: finished_at,
      rows_written: rows_written, error: error, session_id: session_id, details: details }
  end
end
