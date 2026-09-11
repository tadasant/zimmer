# frozen_string_literal: true

# Where a session's category change stops being invisible (tadasant/zimmer#16).
#
# `sessions.category_id` had exactly one write and no context. The
# auto-categorizer logged "Auto-assigned to category X" to the timeline; a human
# dragging the card to a different section logged nothing at all and recorded
# nothing about the answer it replaced. So after one drag the two were
# indistinguishable in the database — and the single most valuable signal Zimmer
# produces, a human stating the correct answer, was destroyed by the UPDATE that
# created it.
#
# This concern closes both halves at the ONE place every surface passes through:
# an `after_update_commit` on the column itself. That is deliberate. The category
# moves through seven write paths — the web `set_category` and cross-section drag
# (`Session.reorder_cards!`), the REST API's `set_category` and `reorder`, and
# the MCP `set_session_category`, `reorder_sessions` and `change_category`
# actions — and hanging the capture off each of them would mean the next path
# silently records nothing.
#
# `category_change_source` names the surface for the audit half. The
# categorizer's own write sets it to CATEGORY_CHANGE_BY_INFERENCE, which is what
# tells this hook the change is not a correction: the job writes its own timeline
# note and its own richer feedback event (it has the context string; this hook
# does not).
#
# `after_update_commit`, not `after_save`: a correction recorded for a
# transaction that rolled back would be a labelled example of something that
# never happened.
module SessionCategorization
  extend ActiveSupport::Concern

  # The value SessionTitleJob stamps on the record before its own write, so this
  # hook can tell the categorizer's answer from a human overruling it.
  CATEGORY_CHANGE_BY_INFERENCE = "inference"

  included do
    # Nullified rather than destroyed on purpose: the eval corpus outlives the
    # sessions it was collected from, which is why it is its own table and why
    # every snapshot is copied onto the correction row.
    has_many :category_feedback_events, dependent: :nullify

    # Which surface is making this write. An `attr_accessor` rather than a
    # thread-local because the writer and the record are always in the same call,
    # and a global would go stale exactly when two requests overlap — the same
    # reasoning AppSetting#policy_change_source is built on.
    attr_accessor :category_change_source

    after_update_commit :record_category_change, if: :saved_change_to_category_id?
  end

  private

  def record_category_change
    return if category_change_source == CATEGORY_CHANGE_BY_INFERENCE

    log_manual_category_change(previous_category)

    # A frozen category is a parked "leave it alone" bucket the categorizer can
    # never pick, so moving a card into one is filing, not a correction: no
    # config could have got it right, and the row would score as a miss forever.
    return if category&.is_frozen?

    CategoryFeedbackEvent.record_correction!(
      session: self,
      corrected_category: category,
      source: category_change_source.presence || CategoryFeedbackEvent::UNATTRIBUTED
    )
  ensure
    # One write, one attribution. Leaving it set would let the NEXT change on the
    # same in-memory record inherit a surface it did not come from.
    self.category_change_source = nil
  end

  # The category the session just left. Guarded like everything else in this
  # after-commit hook: the move has already committed, so a failure here must not
  # turn it into a 500 for the operator who made it.
  def previous_category
    previous_id = saved_change_to_category_id.first
    previous_id && Category.find_by(id: previous_id)
  rescue StandardError => e
    Rails.logger.warn "[SessionCategorization] could not read previous category for session #{id}: #{e.class}: #{e.message}"
    nil
  end

  # The timeline note the manual path never had. Same voice and same level as the
  # auto path's, so the two read as one history of how the card got where it is.
  def log_manual_category_change(previous)
    from = previous ? "\"#{previous.name}\"" : "Uncategorized"
    destination = category ? "category \"#{category.name}\"" : "Uncategorized"

    logs.create!(content: "Moved to #{destination} (was #{from})", level: "info")
  rescue StandardError => e
    # Best-effort, exactly like the auto path's note: a session whose timeline
    # write fails has still been moved, and telling the operator otherwise would
    # be worse than a missing line.
    Rails.logger.warn "[SessionCategorization] could not log category change for session #{id}: #{e.class}: #{e.message}"
  end
end
