# frozen_string_literal: true

# One write to LiveSetting: which fields moved, before → after, and who moved
# them. The edit history the settings page shows, and what a bad edit — the
# guidance above all, which the live model can rewrite for itself — is restored
# from.
#
# `actor_kind` is `human` (the settings page, the iOS app) or `agent` (a live
# conversation's own model, or a session through MCP); `actor` says which, and
# `live_conversation` is set when the live model made the change.
class LiveSettingChange < ApplicationRecord
  HUMAN = "human"
  AGENT = "agent"
  ACTOR_KINDS = [ HUMAN, AGENT ].freeze

  belongs_to :live_conversation, optional: true

  validates :actor_kind, inclusion: { in: ACTOR_KINDS }
  validates :actor, presence: true

  scope :recent_first, -> { order(id: :desc) }
  scope :touching, ->(key) { where("jsonb_exists(changeset, :key)", key: key.to_s) }

  def agent? = actor_kind == AGENT

  def keys = changeset.keys

  def before(key) = changeset.dig(key.to_s, 0)
  def after(key) = changeset.dig(key.to_s, 1)

  def as_api_json
    {
      id: id,
      actor_kind: actor_kind,
      actor: actor,
      live_conversation_id: live_conversation_id,
      changes: changeset.transform_values { |(before, after)| { before: before, after: after } },
      created_at: created_at
    }
  end
end
