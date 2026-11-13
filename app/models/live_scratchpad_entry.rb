# frozen_string_literal: true

# One note on a live conversation's scratchpad: something the live assistant
# (or the person) wants kept in mind for the rest of the conversation — "session
# 1234 cannot merge yet; stop raising it". Every note is in the instructions of
# every turn (LiveConversations::SystemPrompt), so the pad is bounded: at most
# LiveConversations::Scratchpad::MAX_ENTRIES notes of MAX_BODY_CHARS each, and
# a write past either limit is refused with a message saying so — never cut.
#
# Writes go through LiveConversations::Scratchpad, which holds the limits and
# broadcasts the conversation page's panel.
class LiveScratchpadEntry < ApplicationRecord
  MAX_BODY_CHARS = 300
  # Who wrote it: the conversation's own assistant (its `scratchpad` function),
  # the person (the web page, the iOS app's sign-in), or an MCP client on the
  # opt-in `live_conversations` group.
  WRITERS = %w[assistant person mcp].freeze

  belongs_to :live_conversation

  normalizes :body, with: ->(text) { text.to_s.squish }

  validates :body, presence: true, length: { maximum: MAX_BODY_CHARS }
  validates :written_by, inclusion: { in: WRITERS }

  # Who wrote it, as the person's own pages say it.
  def writer_label = { "assistant" => "Live Mode", "person" => "you", "mcp" => "MCP" }.fetch(written_by, written_by)

  def as_api_json
    { id: id, body: body, written_by: written_by, created_at: created_at, updated_at: updated_at }
  end
end
