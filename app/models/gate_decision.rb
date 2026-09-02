# frozen_string_literal: true

# One rating an agent gate made: a `pr-merge-gate` verdict on a pull request, or
# an `issue-work-gate` verdict on an issue.
#
# WHY THIS IS A TABLE AND NOT A FILE
#
# These records lived as arrays in JSON files in `tadasant/tadasant-internal`,
# one auto-merged pull request per append. A gate calibrating a single rating had
# to read the entire file — 3.3 MB and 300 entries for the zimmer PR ledger — to
# find the handful of comparable decisions it wanted. `GateDecisions::Filters`
# is that read, filtered, and it backs both the REST index and the
# `search_gate_decisions` MCP tool.
#
# APPEND-ONLY, AND ENFORCED HERE
#
# A row cannot be updated or destroyed once written. That is not tidiness: until
# now every ledger append was a pull request whose diff another gate read, and a
# direct database write removes the last place a human could ever see one. The
# defence that replaces it is that nothing can be rewritten after the fact — a
# correction is a NEW row citing the one it corrects, so both readings stay
# visible and the audit trail cannot be edited into agreement with itself.
#
# `human_feedback` is not a column here at all. It lives in GateDecisionFeedback,
# reachable only from the browser surface — not from any API key or MCP tool —
# because a note saying "the human said this rating was wrong" is worth exactly as
# much as the guarantee that a machine did not write it. What that boundary does
# and does not guarantee is spelled out on GateDecisionFeedback itself.
class GateDecision < ApplicationRecord
  PR_MERGE = "pr_merge"
  ISSUE_WORK = "issue_work"
  GATES = [ PR_MERGE, ISSUE_WORK ].freeze

  # How the row arrived. `import` is the one-time backfill of the JSON ledgers;
  # `mcp` is a gate calling `record_gate_decision`; `api` is a POST to
  # /api/v1/gate_decisions. Stamped by the writer, never accepted from a caller.
  IMPORT = "import"
  MCP = "mcp"
  API = "api"
  RECORDED_VIA = [ IMPORT, MCP, API ].freeze

  MAX_URL_LENGTH = 2048
  MAX_SURFACE_LENGTH = 200

  # A guard, not a tuning knob. The entries average 11.5 KB and the largest seen
  # is well under this; a payload past it is a caller sending something that is
  # not a gate entry.
  MAX_PAYLOAD_BYTES = 512.kilobytes

  belongs_to :writing_session, class_name: "Session", optional: true
  # `restrict_with_exception`, not `destroy`: a GateDecision can never be
  # destroyed, so a cascade here is unreachable today — and leaving one in place
  # is a path that would quietly start deleting human feedback if the parent's
  # guard were ever relaxed.
  has_many :feedbacks, class_name: "GateDecisionFeedback", dependent: :restrict_with_exception,
           inverse_of: :gate_decision

  validates :gate, inclusion: { in: GATES }
  validates :surface, presence: true, length: { maximum: MAX_SURFACE_LENGTH }
  validates :recorded_via, inclusion: { in: RECORDED_VIA }
  validates :artifact_url, length: { maximum: MAX_URL_LENGTH }, allow_nil: true
  validates :producing_session_url, length: { maximum: MAX_URL_LENGTH }, allow_nil: true
  validate :payload_must_be_an_object
  validate :payload_must_be_within_size

  scope :for_gate, ->(gate) { where(gate: gate) }
  scope :for_surface, ->(surface) { where(surface: surface) }
  scope :with_decision, ->(decision) { where(decision: decision) }
  scope :for_artifact, ->(url) { where(artifact_url: url) }
  scope :decided_between, ->(from, to) {
    scope = all
    scope = scope.where(decided_at: from..) if from
    scope = scope.where(decided_at: ..to) if to
    scope
  }
  # Newest first, with `id` breaking the tie inside a day. `decided_at` is a date,
  # so without the second key the order of same-day decisions would be arbitrary —
  # and same-day is the common case for a gate rating a burst of PRs.
  scope :recent_first, -> { order(decided_at: :desc, id: :desc) }
  scope :with_human_feedback, -> { where(id: GateDecisionFeedback.select(:gate_decision_id)) }

  # Enforced here rather than with a Postgres trigger, which would be stronger but
  # cannot survive this app's Ruby schema dump — see the migration. So the honest
  # statement of the guarantee is: every path that goes through a model instance
  # is append-only, and `update_all` / `delete_all` / raw SQL are not. Nothing in
  # the app takes those paths against this table, and the API and MCP surfaces
  # expose no update or destroy at all.
  before_update { raise ActiveRecord::ReadOnlyRecord, "GateDecision is append-only: record a new decision instead of editing one" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "GateDecision is append-only and cannot be deleted" }

  # Substring search across the whole entry.
  #
  # `payload::text ILIKE` rather than a tsvector: the corpus is ~1,500 rows and
  # ~13 MB, which Postgres scans in tens of milliseconds, and substring matching
  # is what a caller searching for `air_prepare_service.rb` or `#722` actually
  # means. A word-stemmed index would be faster and would answer a different
  # question.
  def self.matching_text(query)
    return all if query.blank?

    where("gate_decisions.payload::text ILIKE :q", q: "%#{sanitize_sql_like(query.to_s)}%")
  end

  def self.normalize_gate(value)
    key = value.to_s.strip.downcase.tr("-", "_")
    key = PR_MERGE if %w[pr pr_merge_gate pr_gate].include?(key)
    key = ISSUE_WORK if %w[issue issue_work_gate issue_gate].include?(key)
    GATES.include?(key) ? key : nil
  end

  # Surfaces are named by the agent root / repo they gate, lowercased with
  # underscores — `zimmer`, `strad_production`, `tadasant_internal`. Normalized on
  # the way in so a caller writing "Zimmer" or "strad-production" lands in the same
  # bucket as the importer rather than founding a second one.
  def self.normalize_surface(value)
    value.to_s.strip.downcase.tr("-", "_").gsub(/\s+/, "_").presence
  end

  def title
    payload["title"].presence
  end

  private

  def payload_must_be_an_object
    errors.add(:payload, "must be a JSON object") unless payload.is_a?(Hash)
  end

  def payload_must_be_within_size
    return unless payload.is_a?(Hash)

    size = payload.to_json.bytesize
    return if size <= MAX_PAYLOAD_BYTES

    errors.add(:payload, "is #{size} bytes, over the #{MAX_PAYLOAD_BYTES}-byte limit")
  end
end
