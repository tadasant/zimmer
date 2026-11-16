# frozen_string_literal: true

# Where one settled session hierarchy's wall-clock went.
#
# One row per hierarchy root, written by CycleTimes::Analyzer when every
# session in the hierarchy is archived — so the Cycle Time page, the REST API
# and `get_cycle_time` read precomputed numbers and never parse a transcript on
# a request. A row exists for ineligible hierarchies too, carrying the reason,
# so "how many tasks were autonomous" has a denominator and the sweep does not
# re-evaluate them.
#
# Offsets in `lanes`, `hierarchy_segments` and `top_segments` are seconds from
# `started_at`. A segment is `[start, end, category, detail]`; categories are
# CycleTimes::Categories keys.
class CycleTimeAnalysis < ApplicationRecord
  belongs_to :root_session, class_name: "Session"

  scope :eligible, -> { where(eligible: true) }
  scope :ineligible, -> { where(eligible: false) }
  scope :finished_between, ->(from, to) { where(finished_at: from..to) }
  scope :current, -> { where(algorithm_version: CycleTimes::Analyzer::VERSION) }

  # Every column but the three segment arrays — what a listing needs. The
  # arrays are most of a row's weight and only the detail page draws them.
  HEAVY_COLUMNS = %w[lanes hierarchy_segments top_segments].freeze

  def self.list_columns
    (column_names - HEAVY_COLUMNS).map { |c| "#{table_name}.#{c}" }
  end

  def wait_seconds
    category_seconds.sum { |key, seconds| CycleTimes::Categories.wait?(key) ? seconds.to_f : 0.0 }
  end

  def ineligible_reason_label
    CycleTimes::Eligibility::REASONS[ineligible_reason] || ineligible_reason
  end

  # The categories, largest first, with their share of the wall-clock.
  def ranked_categories
    category_seconds.map { |key, seconds| [ key, seconds.to_f ] }
                    .select { |_, seconds| seconds.positive? }
                    .sort_by { |_, seconds| -seconds }
  end
end
