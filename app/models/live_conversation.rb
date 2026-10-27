# frozen_string_literal: true

# A Live Mode conversation: one continuous thread with a fast OpenAI model whose
# system prompt is the `live-mode` agent root's AGENTS.md, which answers quick
# things itself and hands anything slow to Zimmer's own MCP surface. `mode` is
# how it runs right now, typed or spoken; it switches mid-thread (switch_mode!)
# and the thread carries both.
#
# Not a Session. A Session is an agent process — spawned, heartbeated, swept when
# its start stalls, reaped with its clone — and a live conversation has no
# process: the model runs at OpenAI, a text turn is one job, a voice call is the
# browser's or the phone's. What it shares with sessions is what it delegates to
# them. See docs/sessions/live.md.
#
# Lifecycle: preparing (AGENTS.md being fetched) → active → ended, or failed
# when it could not be prepared. At most one open conversation at a time.
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
  validate :mode_instructions_is_a_map_of_modes

  scope :unfinished, -> { where(status: OPEN_STATUSES) }
  scope :recent_first, -> { order(updated_at: :desc, id: :desc) }

  after_update_commit :broadcast_header, if: -> { saved_change_to_status? || saved_change_to_mode? || saved_change_to_responding_since? || saved_change_to_mcp_servers? || saved_change_to_title? }

  # The TurnSource surfaces a client driving a conversation can be.
  CLIENT_SURFACES = %w[web ios carplay mcp].freeze

  # @return [String, nil] the surface, or nil for anything not on the list
  def self.normalize_client_surface(value)
    CLIENT_SURFACES.include?(value.to_s) ? value.to_s : nil
  end

  def self.current
    unfinished.order(id: :desc).first
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
    title.presence || "#{LiveConversations::LABEL} · #{created_at&.strftime('%b %-d, %H:%M')}"
  end

  # The style text the agent root ships for this mode, or nil when it ships none.
  def style_for(mode_key) = mode_instructions.is_a?(Hash) ? mode_instructions[mode_key.to_s].presence : nil

  # Typed ⇄ spoken. The model follows the mode, because each path has its own.
  def switch_mode!(mode_key)
    target = LiveConversations.mode(mode_key)
    return if mode == target.key

    update!(mode: target.key, model: target.model, last_activity_at: Time.current)
  end

  def enabled_mcp_servers = Array(mcp_servers)

  # The sessions this conversation has touched through its tool calls — started,
  # checked on, followed up, searched for — newest first. Read off the tool turns:
  # the session named in a call's arguments, and the ids its output writes the
  # way Zimmer's own tools write them (`**ID:** 1101`, a `/sessions/1101` URL,
  # "session #1101"). What a client shows beside the conversation, so the person
  # sees which sessions are being talked about: the car's call screen draws it.
  #
  # @param limit [Integer] at most this many, the most recently named first
  # @return [Array<Integer>]
  def referenced_session_ids(limit: REFERENCED_SESSIONS_LIMIT)
    ids = []
    turns.where(role: "tool").order(id: :desc).each do |turn|
      self.class.session_ids_in_arguments(turn.tool_arguments).each { |id| ids << id unless ids.include?(id) }
      self.class.session_ids_in_text(turn.tool_output.to_s).each { |id| ids << id unless ids.include?(id) }
      break if ids.size >= limit
    end
    ids.first(limit)
  end

  REFERENCED_SESSIONS_LIMIT = 12
  REFERENCED_ARGUMENT_KEYS = %w[session_id id session_ids ids].freeze
  REFERENCED_TEXT_PATTERNS = [ /\*\*ID:\*\*\s*(\d+)/, %r{/sessions/(\d+)}, /[Ss]ession\s+#(\d+)/ ].freeze

  # @param arguments [Hash, nil] a tool turn's arguments; a Zimmer gateway call
  #   names its session under `arguments`
  # @return [Array<Integer>]
  def self.session_ids_in_arguments(arguments)
    return [] unless arguments.is_a?(Hash)

    inner = arguments["arguments"].is_a?(Hash) ? arguments["arguments"] : arguments
    REFERENCED_ARGUMENT_KEYS.flat_map { |key| Array(inner[key]) }.filter_map { |value| value.to_s.match?(/\A\d+\z/) ? value.to_i : nil }.uniq
  end

  # @return [Array<Integer>] the ids `text` names, in the order it names them, each once
  def self.session_ids_in_text(text)
    REFERENCED_TEXT_PATTERNS.flat_map { |pattern| text.to_enum(:scan, pattern).map { Regexp.last_match.then { |m| [ m.begin(0), m[1].to_i ] } } }
      .sort_by(&:first).map(&:last).uniq
  end

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
      voice: voice?,
      label: LiveConversations::LABEL,
      mode_label: live_mode.label,
      status: status,
      title: display_title,
      agent_root: agent_root,
      model: model,
      instructions_source: instructions_source,
      mode_styles: LiveConversations.mode_keys.index_with { |key| style_for(key) ? "agent_root" : "zimmer_default" },
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

  def mode_instructions_is_a_map_of_modes
    return if mode_instructions.is_a?(Hash) && mode_instructions.all? { |key, text| LiveConversations.mode_keys.include?(key) && text.is_a?(String) }

    errors.add(:mode_instructions, "must map text/voice to the agent root's style text")
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
