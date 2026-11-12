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

  # Whether the Live mode guidance in effect was last written by an agent
  # session rather than a person: through MCP (`action_live_settings`), or by a
  # live conversation whose own thread an agent wrote into. The guidance is in
  # every conversation's system prompt, so text an agent put there can tell the
  # live model to deliver something whenever the person speaks;
  # HumanMessageCapture records no Live Mode message while this is true. A person
  # saving the guidance (settings page or iOS app) clears it. A change the live
  # model made at a person's request in a clean conversation does not set it.
  def self.guidance_written_by_an_agent?
    latest = touching(:guidance).recent_first.first
    return false if latest.nil? || !latest.agent?

    latest.live_conversation.nil? || latest.live_conversation.agent_written?
  end

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
