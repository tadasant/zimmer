# frozen_string_literal: true

# One session's place in an "Analyze All" queue.
#
# `state` is the item's own progress, not the analysis session's status: an item
# is SUCCEEDED the moment a current OutcomeAnalysis exists for its session,
# which is the thing the batch was for — even if the analysis session goes on to
# tidy up afterwards. That is what frees the concurrency slot promptly instead of
# holding it until the analyzer happens to archive itself.
class OutcomeAnalysisBatchItem < ApplicationRecord
  QUEUED = "queued"
  RUNNING = "running"
  SUCCEEDED = "succeeded"
  FAILED = "failed"
  CANCELED = "canceled"
  STATES = [ QUEUED, RUNNING, SUCCEEDED, FAILED, CANCELED ].freeze
  TERMINAL_STATES = [ SUCCEEDED, FAILED, CANCELED ].freeze

  belongs_to :batch, class_name: "OutcomeAnalysisBatch",
    foreign_key: :outcome_analysis_batch_id, inverse_of: :items
  belongs_to :session
  belongs_to :analysis_session, class_name: "Session", optional: true

  validates :state, inclusion: { in: STATES }

  scope :queued, -> { where(state: QUEUED) }
  scope :running, -> { where(state: RUNNING) }
  scope :in_order, -> { order(:position, :id) }

  def terminal? = TERMINAL_STATES.include?(state)
end
