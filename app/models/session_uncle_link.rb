# frozen_string_literal: true

# One "uncle" edge: `uncle_session` is senior to `session`.
#
# Written when a session queues or interrupts another session — the assumption
# being that a session which inspected another and decided to redirect it holds
# information the other does not. Unlike the spawn edge on
# `sessions.parent_session_id`, this one is many-to-many and can join two
# sessions with no spawn relationship at all, which is what turns the lineage
# graph from a tree into a DAG.
#
# The rules about WHEN an edge may be written — the inversion case, and the
# acyclicity invariant — live in Sessions::RecordUncleEdge. Nothing else should
# create these rows.
class SessionUncleLink < ApplicationRecord
  belongs_to :session
  belongs_to :uncle_session, class_name: "Session"

  validates :session_id, uniqueness: { scope: :uncle_session_id }
  validate :must_not_be_self_edge

  scope :for_session, ->(session_id) { where(session_id: session_id) }
  scope :from_uncle, ->(uncle_id) { where(uncle_session_id: uncle_id) }

  private

  # A session messaging itself is not a lineage fact. Guarded here as well as in
  # the recorder so no future writer can create one by hand.
  def must_not_be_self_edge
    return if session_id.blank? || uncle_session_id.blank?
    return if session_id != uncle_session_id

    errors.add(:uncle_session_id, "cannot be the session itself")
  end
end
