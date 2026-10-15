# frozen_string_literal: true

# A Live Mode or Live Voice conversation: one continuous thread with a fast
# OpenAI model whose system prompt is an agent root's AGENTS.md, which answers
# quick things itself and hands anything slow to Zimmer's own MCP surface.
#
# Not a Session. A Session is an agent process — spawned, heartbeated, swept when
# its start stalls, reaped with its clone — and a live conversation has no
# process: the model runs at OpenAI, a text turn is one job, a voice call is the
# browser's or the phone's. What it shares with sessions is what it delegates to
# them. See docs/sessions/live.md.
#
# Lifecycle: preparing (AGENTS.md being fetched) → active → ended, or failed
# when it could not be prepared. At most one open conversation per mode.
class LiveConversation < ApplicationRecord
  include BroadcastsThroughService

  PREPARING = "preparing"
  ACTIVE = "active"
  ENDED = "ended"
  FAILED = "failed"
  STATUSES = [ PREPARING, ACTIVE, ENDED, FAILED ].freeze
  OPEN_STATUSES = [ PREPARING, ACTIVE ].freeze

  # A text turn whose job died mid-flight must not leave the thread locked
  # forever; after this long a new message may take over. A live reply renews
  # the claim before every request and tool call (TextReply#heartbeat!), each
  # bounded by a timeout of 90 seconds or less, so only a dead job goes stale.
  RESPONDING_STALE_AFTER = 5.minutes

  has_many :turns, -> { order(:id) }, class_name: "LiveConversationTurn", dependent: :delete_all, inverse_of: :live_conversation

  validates :mode, inclusion: { in: ->(_) { LiveConversations.mode_keys } }
  validates :status, inclusion: { in: STATUSES }
  validates :agent_root, :model, presence: true
  validate :mcp_servers_is_a_list_of_names

  scope :unfinished, -> { where(status: OPEN_STATUSES) }
  scope :for_mode, ->(mode) { where(mode: mode.to_s) }
  scope :recent_first, -> { order(updated_at: :desc, id: :desc) }

  after_update_commit :broadcast_header, if: -> { saved_change_to_status? || saved_change_to_responding_since? || saved_change_to_mcp_servers? || saved_change_to_title? }

  def self.current(mode)
    unfinished.for_mode(mode).order(id: :desc).first
  end

  def live_mode = LiveConversations.mode(mode)
  def voice? = live_mode.voice?
  def text? = live_mode.text?

  def preparing? = status == PREPARING
  def active? = status == ACTIVE
  def ended? = status == ENDED
  def failed? = status == FAILED
  def open? = OPEN_STATUSES.include?(status)

  def responding?
    responding_since.present? && responding_since > RESPONDING_STALE_AFTER.ago
  end

  def display_title
    title.presence || "#{live_mode.label} · #{created_at&.strftime('%b %-d, %H:%M')}"
  end

  def enabled_mcp_servers = Array(mcp_servers)

  def end!
    return if ended? || failed?

    update!(status: ENDED, ended_at: Time.current, responding_since: nil)
  end

  def fail!(message)
    update!(status: FAILED, error_message: message.to_s.truncate(2_000), ended_at: Time.current, responding_since: nil)
  end

  def touch_activity!
    update_column(:last_activity_at, Time.current)
  end

  def stream_name = "live_conversation_#{id}"
  def turns_dom_id = "live_conversation_#{id}_turns"
  def header_dom_id = "live_conversation_#{id}_header"

  def as_api_json(include_turns: false)
    json = {
      id: id,
      mode: mode,
      label: live_mode.label,
      status: status,
      title: display_title,
      agent_root: agent_root,
      model: model,
      instructions_source: instructions_source,
      mcp_servers: enabled_mcp_servers,
      responding: responding?,
      error_message: error_message,
      created_at: created_at,
      updated_at: updated_at,
      last_activity_at: last_activity_at,
      ended_at: ended_at
    }
    json[:turns] = turns.map(&:as_api_json) if include_turns
    json
  end

  private

  def mcp_servers_is_a_list_of_names
    return if mcp_servers.is_a?(Array) && mcp_servers.all? { |name| name.is_a?(String) && name.present? }

    errors.add(:mcp_servers, "must be a list of catalog server names")
  end

  def broadcast_header
    broadcaster.broadcast_partial(
      action: :replace,
      stream: stream_name,
      target: header_dom_id,
      partial: "live_conversations/header",
      locals: { conversation: self }
    )
  end
end
