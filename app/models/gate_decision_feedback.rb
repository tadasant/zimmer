# frozen_string_literal: true

# What a human said about a gate's rating, after the fact.
#
# THIS IS THE ONE THING IN THE LEDGER A MACHINE MUST NOT BE ABLE TO WRITE.
#
# Every other field on a GateDecision is a machine's account of its own
# reasoning, and a gate reading the ledger weighs it as such. A feedback row is
# different in kind: it is the record of a person overruling a gate, and it is
# the highest-authority signal in the corpus — which is exactly why fabricating
# one is the attack worth defending against. `PR_MERGE_GATE_NO_SELF_ESCALATION.md`
# makes the point in the gate's own words: a ledger-shaped write carrying an
# invented `human_feedback` note "would sail through a structural check and never
# be seen by a human."
#
# So the defence is structural, in three parts:
#
#   * There is no MCP tool that writes here, and none that can. The write path is
#     GateDecisionFeedbacksController, which is an ApplicationController
#     descendant — the browser. Api::BaseController authenticates an API key the
#     whole agent fleet shares, so it establishes a caller but not a person, and
#     it deliberately has no feedback-append action.
#   * `author` is resolved at that boundary from `User.admin`, never read from
#     the request body. Same rule as HumanMessage, for the same reason.
#   * Rows are append-only. A note cannot be edited into saying something else,
#     and cannot be deleted to make a gate look better than it was.
#
# The `imported` channel is the one exception to "a human typed this", and it is
# honest about itself: those rows are the `human_feedback` arrays transcribed
# from the JSON ledgers by the one-time backfill, where the authorship the source
# recorded is whatever it recorded — often nothing, which is why `author` is
# nullable on that channel rather than filled in with a plausible guess.
class GateDecisionFeedback < ApplicationRecord
  WEB_UI = "web_ui"
  IMPORTED = "imported"
  CHANNELS = [ WEB_UI, IMPORTED ].freeze

  MAX_NOTE_LENGTH = 20_000
  MAX_VERDICT_LENGTH = 200

  belongs_to :gate_decision, inverse_of: :feedbacks

  validates :verdict, presence: true, length: { maximum: MAX_VERDICT_LENGTH }
  validates :note, length: { maximum: MAX_NOTE_LENGTH }, allow_nil: true
  validates :channel, inclusion: { in: CHANNELS }
  validates :author, presence: true, if: -> { channel == WEB_UI }

  scope :chronological, -> { order(:received_at, :id) }

  before_update { raise ActiveRecord::ReadOnlyRecord, "GateDecisionFeedback is append-only: add another note instead of editing one" }
  before_destroy do
    raise ActiveRecord::ReadOnlyRecord, "GateDecisionFeedback is append-only and cannot be deleted" unless destroyed_by_association
  end

  # Falls back to the raw key rather than dropping the row: a human said it even
  # if the roster has since changed. Same treatment as HumanMessage#display_name.
  def display_name
    return author if author.blank?

    User.find_by(key: author)&.display_name || author
  end
end
