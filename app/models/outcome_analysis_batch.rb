# frozen_string_literal: true

# An "Analyze All" run: the filter set it was created from, the number of
# analyses allowed in flight at once, and one item per session that matched.
#
# The concurrency number is honored as typed, including the ill-advised ones —
# 100 really does try to keep a hundred analysis sessions in flight. What makes
# that survivable is that the batch is visible and stoppable: the ledger renders
# its live counts, and Stop marks it canceled so the pump stops spawning.
#
# That is the web UI's contract. A batch started over MCP is held to
# AGENT_MAX_CONCURRENCY instead — see OutcomeAnalyses::StartBatch.
class OutcomeAnalysisBatch < ApplicationRecord
  RUNNING = "running"
  CANCELED = "canceled"
  COMPLETED = "completed"
  STATUSES = [ RUNNING, CANCELED, COMPLETED ].freeze

  # The floor is 1 (zero would be a batch that never starts). There is
  # deliberately no ceiling on the web UI — see the class comment.
  MIN_CONCURRENCY = 1
  # Past this, "concurrent analyses" stops describing anything the deployment
  # can do and starts describing a typo. The batch still runs; the ledger just
  # says out loud that it is far past what the spot gate will let through.
  ADVISORY_CONCURRENCY = 10

  # Where the batch was started from. The button on /outcomes is a human at a
  # keyboard; `action_outcome_analysis` is an agent, or a human driving an MCP
  # client, and either way nobody watched the ledger when it was clicked.
  STARTED_VIA_WEB_UI = "web_ui"
  STARTED_VIA_MCP = "mcp"
  STARTED_VIA = [ STARTED_VIA_WEB_UI, STARTED_VIA_MCP ].freeze

  # The ceiling an MCP-started batch is held to — the web form's own default.
  # A human can type any number and is told when it is ill-advised; an agent is
  # held to what a human is offered before they change anything, and to one
  # running batch at a time (the partial unique index on `started_via`), so the
  # cap cannot be multiplied by calling the tool again.
  AGENT_MAX_CONCURRENCY = 3

  has_many :items, class_name: "OutcomeAnalysisBatchItem",
    foreign_key: :outcome_analysis_batch_id, dependent: :destroy, inverse_of: :batch
  belongs_to :started_by_session, class_name: "Session", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :started_via, inclusion: { in: STARTED_VIA }
  validates :concurrency, numericality: { only_integer: true, greater_than_or_equal_to: MIN_CONCURRENCY }

  scope :active, -> { where(status: RUNNING) }
  scope :recent, -> { order(id: :desc) }
  scope :started_via_mcp, -> { where(started_via: STARTED_VIA_MCP) }

  def running? = status == RUNNING
  def canceled? = status == CANCELED
  def completed? = status == COMPLETED
  def finished? = !running?
  def started_via_mcp? = started_via == STARTED_VIA_MCP

  # One grouped query rather than five counts, because the ledger renders this
  # for every recent batch on every page load.
  def item_counts
    @item_counts ||= items.group(:state).count
  end

  def count_of(state) = item_counts.fetch(state, 0)

  def queued_count = count_of(OutcomeAnalysisBatchItem::QUEUED)
  def running_count = count_of(OutcomeAnalysisBatchItem::RUNNING)
  def succeeded_count = count_of(OutcomeAnalysisBatchItem::SUCCEEDED)
  def failed_count = count_of(OutcomeAnalysisBatchItem::FAILED)
  def canceled_count = count_of(OutcomeAnalysisBatchItem::CANCELED)

  def finished_item_count = succeeded_count + failed_count + canceled_count

  # The number of items that still exist. `total_count` is what the batch was
  # created to cover and never moves; an item goes away when its session is
  # deleted (the foreign key cascades), so measuring progress against the frozen
  # figure would leave a finished batch reading "7/10" forever.
  def live_item_count = item_counts.values.sum

  def progress_percent
    denominator = live_item_count
    return 100 if denominator.zero?
    ((finished_item_count.to_f / denominator) * 100).round
  end

  def advisory_concurrency? = concurrency > ADVISORY_CONCURRENCY

  # The filters this batch was built from, for the "matching these filters" line
  # in the UI. Stored verbatim so the batch explains itself long after the
  # ledger's own filter inputs have moved on.
  def filter_summary
    OutcomeAnalyses::LedgerFilters.from_hash(filters).summary
  end
end
