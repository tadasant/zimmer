# frozen_string_literal: true

# One saved outcome analysis of one archived session's transcript.
#
# Zimmer never writes one of these on its own — the analysis is expensive, so it
# happens only when a human clicks Analyze (or an explicit API/MCP call arrives).
# The two write paths are OutcomeAnalyses::Save's callers:
# Mcp::Tools::SaveOutcomeAnalysis and Api::V1::OutcomeAnalysesController.
#
# The Segment tree lives in `root`. Nothing that renders a *list* reads it: the
# ledger and the stats view are served entirely from the denormalized columns
# beside it, which is what keeps them to one indexed query at any number of
# analyses. Use the `without_tree` scope wherever the tree is not needed.
class OutcomeAnalysis < ApplicationRecord
  SCHEMA_VERSION = "1"

  belongs_to :session
  # The session that produced the analysis. Optional both ways: an analysis can
  # arrive from a human's curl, and one whose analyzer session was deleted is
  # still a valid reading of the transcript.
  belongs_to :analyzer_session, class_name: "Session", optional: true

  # A re-analysis supersedes its predecessor rather than overwriting it, so
  # `current` is what every surface means by "the analysis".
  scope :current, -> { where(superseded_at: nil) }
  scope :superseded, -> { where.not(superseded_at: nil) }

  # Every column but the tree. The tree of a single analysis is small; ten
  # thousand of them in one page render is not.
  #
  # Apply it LAST. It sets an explicit select list, so a `.count` taken after it
  # becomes `COUNT(col, col, …)` — which is not a function Postgres has. Narrow
  # the columns once the counting is done.
  scope :without_tree, -> { select(column_names - [ "root" ]) }

  scope :created_between, ->(from, to) {
    scope = all
    scope = scope.where(session_created_at: from..) if from
    scope = scope.where(session_created_at: ..to) if to
    scope
  }

  validates :schema_version, presence: true
  validates :root_outcome, inclusion: { in: OutcomeAnalyses::SegmentTree::OUTCOME_KINDS }
  validates :segment_count, :failure_segment_count, :max_depth,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def success? = root_outcome == OutcomeAnalyses::SegmentTree::SUCCESS
  def failure? = root_outcome == OutcomeAnalyses::SegmentTree::FAILURE
  def current? = superseded_at.nil?

  def success_segment_count = segment_count - failure_segment_count

  # Depth-first, matching the id scheme, so the flamegraph and the segment table
  # below it walk the tree in the same order.
  def each_segment(&block)
    OutcomeAnalyses::SegmentTree.each_segment(root, 0, &block)
  end
end
