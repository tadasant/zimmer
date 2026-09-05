class Log < ApplicationRecord
  include BroadcastsThroughService

  belongs_to :session

  LEVELS = %w[info error debug warning verbose].freeze

  # The raw stdout of the runtime CLI: AgentSessionJob buffers every line the
  # process emits into a row at this level. It is the overwhelming majority of
  # the table, and the only level the session timeline hides by default — it
  # renders under the `verbose` filter and nowhere else (SessionsController's
  # `show-logs` filter is `where.not(level: "verbose")`).
  VERBOSE_LEVEL = "verbose"

  # RETENTION POLICY — see LogRetentionJob, which enforces it.
  #
  # The table had none until tadasant/zimmer#437: it is written on the hot path of
  # every session, so it grew with total fleet activity forever. On staging that
  # reached 124M rows / 24 GB of a 31 GB volume, filled the disk, and put Postgres
  # into a checkpointer-PANIC crash-recovery loop.
  #
  # Two windows rather than one, because the two kinds of row are worth very
  # different amounts:
  #
  #   verbose — raw CLI stdout. High volume, and the transcript already holds the
  #     same conversation in a form the UI actually renders. Kept long enough to
  #     debug a live incident, not longer.
  #
  #   everything else — Zimmer's own timeline lines ("[State Machine] …",
  #     "Process spawned with PID …", enqueued-message bookkeeping). Low volume,
  #     and they are the readable history of an archived session, so they are kept
  #     a quarter.
  #
  # Both are absolute ages, not per-session counts: a bound that depends on how
  # many sessions exist is not a bound.
  VERBOSE_RETENTION = 7.days
  RETENTION = 90.days

  # Validations
  validates :content, presence: true
  validates :level, inclusion: { in: LEVELS, message: "%{value} is not a valid log level" }

  # Turbo Stream broadcasting
  after_create_commit -> { broadcast_append_to_timeline }

  # Rows the retention policy says are expired, as of `now`.
  #
  # The `verbose` window is a subset of the general one by construction
  # (VERBOSE_RETENTION < RETENTION), which is why LogRetentionJob runs two passes
  # rather than one predicate: each pass is a plain range the planner can drive
  # off an index.
  scope :expired, ->(now = Time.current) { where(created_at: ...(now - RETENTION)) }
  scope :expired_verbose, ->(now = Time.current) {
    where(level: VERBOSE_LEVEL).where(created_at: ...(now - VERBOSE_RETENTION))
  }

  private

  def broadcast_append_to_timeline
    timeline_item = {
      type: "log",
      level: level,
      content: content,
      timestamp: created_at,
      sort_time: created_at
    }

    broadcaster.broadcast_partial(
      action: :append,
      stream: "session_#{session_id}_timeline",
      target: "session_#{session_id}_timeline",
      partial: "timeline_items/item",
      locals: { item: timeline_item }
    )
  end
end
