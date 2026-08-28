# frozen_string_literal: true

# Everything Zimmer knows a named human said anywhere in one session's
# hierarchy, gathered for the consumers that show it: the session detail
# screen, and the `get_session` and `get_session_provenance` MCP tools (and the
# REST show action alongside them).
#
# Nothing here is injected into an agent's turn. A session reads its provenance
# by calling `get_session_provenance`, which is why that tool's description —
# not a block in the prompt — is where the caveats below have to be stated.
#
# Records are gathered across the WHOLE tree — the origin session, this session,
# and every sibling and descendant — because in practice the human speaks to a
# router and the session doing the work never hears it directly. But gathering
# them together is only safe if the reader can always tell two things apart:
#
#   * HERE      — a human spoke to *this* session. This answers "did a human
#                 ask for this, in this conversation?"
#   * ELSEWHERE — a human spoke to another session in the same hierarchy. Real
#                 context about original intent, NOT an instruction to this
#                 session.
#
# Every rendering must mark which. Presenting an elsewhere message as a turn in
# this session would be exactly the laundering the whole feature exists to
# prevent.
class SessionHumanMessages
  HERE = :here
  ELSEWHERE = :elsewhere

  # Name of the MCP tool that serves this record. Named once so the tool and the
  # cost page's detector for what it returns cannot drift apart.
  MCP_TOOL_NAME = "get_session_provenance"

  # One record as its consumers see it: the message, where in the hierarchy it
  # was authored, and whether that is this session.
  Entry = Struct.new(:message, :origin, :session_id, :session_label, keyword_init: true) do
    def here? = origin == HERE
    def elsewhere? = origin == ELSEWHERE

    def author = message.author
    def display_name = message.display_name
    def author_notes = message.author_notes
    def channel = message.channel
    def content = message.content
    def occurred_at = message.occurred_at
    def entry_point = message.entry_point

    # Where the human was speaking, named so a reader can weigh it. Deliberately
    # explicit about the elsewhere case rather than leaving it to a subtle
    # visual difference.
    def authored_in
      here? ? "this session (##{session_id})" : "session ##{session_id} — #{session_label}"
    end

    def channel_label = message.channel_label
  end

  attr_reader :session

  def initialize(session, hierarchy: nil)
    @session = session
    @hierarchy = hierarchy
  end

  def hierarchy
    @hierarchy ||= SessionHierarchy.new(session)
  end

  # Every record in the hierarchy, oldest first. Sorted by when the human spoke
  # rather than by session, because the reader is reconstructing a conversation.
  def entries
    @entries ||= begin
      labels = hierarchy.nodes.to_h { |node| [ node.id, "#{node.agent_root_label} · #{node.label}" ] }

      HumanMessage.where(session_id: hierarchy.session_ids)
        .includes(:user)
        .chronological
        .map do |message|
          Entry.new(
            message: message,
            origin: message.session_id == session.id ? HERE : ELSEWHERE,
            session_id: message.session_id,
            session_label: labels[message.session_id] || "unknown"
          )
        end
    end
  end

  def any? = entries.any?
  def here_entries = entries.select(&:here?)
  def elsewhere_entries = entries.select(&:elsewhere?)
  def here_count = here_entries.size
  def elsewhere_count = elsewhere_entries.size

  # True when a named human spoke to THIS session. This is the question a merge
  # gate asks: a message authored elsewhere in the hierarchy is context, not
  # authorization to act here.
  def human_message_here? = here_entries.any?

  # One entry per human who both speaks in the newest `limit` entries and has a
  # roster note — the `notes` column an operator writes at /supervisor/users.
  # Public because every surface that renders the record has to be able to
  # render the notes with it: a session weighing "may I do this?" needs to know
  # whose word is final, and a record served without that is missing the part
  # that answers the question.
  def described_authors(limit:)
    entries.last(limit).select { |entry| entry.author_notes.present? }.uniq(&:author)
  end

  # A human's own words are untrusted text going into output an agent reads
  # structurally — the markdown `get_session` and `get_session_provenance`
  # return, and the lines and fences inside it. Anything shaped like the framing
  # Zimmer wraps this record in is neutralized so it cannot pose as that framing
  # when the tool result lands in a reader's context. The tag list is
  # deliberately broader than what any current surface emits: the cost of an
  # extra alternative is nothing, and the cost of a missing one is a forged
  # `here` message. Same treatment AgentSessionJob gives an attached filename.
  def self.neutralize_tags(text)
    text.to_s.gsub(%r{</?\s*(human-messages|message|info|people|person|session-hierarchy)\b[^>]*>}i) { |tag| tag.tr("<>", "‹›") }
  end

  # Stricter treatment for a value interpolated into ONE LINE of the markdown
  # `get_session` and `get_session_provenance` return — a hierarchy outline row,
  # a `- **[here]** …` bullet, a quoted handle.
  #
  # This is not paranoia about the values themselves — a session's title is
  # writable by the session (`action_session` → `update_title`), and a Slack
  # channel name comes from an external API. Either could otherwise carry a
  # newline, open a second bullet or outline row, and forge an entry in the
  # Human Messages section — manufacturing the human authorization this whole
  # record exists to make unforgeable. Newlines are what makes that possible, so
  # they go; nothing legitimate in a title, agent root, or Slack channel name
  # needs one.
  def self.sanitize_for_markdown_line(text)
    neutralize_tags(text).tr("<>\"", "‹›＂").delete("\n\r")
  end

  # For a value emitted inside a fenced code block. A fence is closed by a line
  # of three backticks, so a run of three or more is neutralized the same way a
  # closing tag is: replaced with a lookalike, never deleted, so the reader can
  # still see what was said.
  def self.sanitize_for_fence(text)
    neutralize_tags(text).gsub(/`{3,}/) { |run| "ˋ" * run.length }
  end
end
