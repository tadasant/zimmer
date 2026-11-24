# frozen_string_literal: true

# One thing that happened to a session, as Zimmer's MCP server publishes it
# (SessionEvents): a row is one MCP Events occurrence.
#
# `data` is the occurrence's payload. For `session.message` it carries words an
# agent wrote, so every reader treats it as untrusted, the way it treats a tool
# result.
class SessionEvent < ApplicationRecord
  # A cursor older than this is answered `truncated`.
  RETENTION = 14.days

  belongs_to :session

  validates :name, inclusion: { in: ->(_) { SessionEvents::NAMES } }
  validates :event_id, presence: true

  scope :expired, ->(now = Time.current) { where(created_at: ...(now - RETENTION)) }

  # @return [Hash] the SEP's `EventOccurrence`
  def as_occurrence
    { eventId: event_id, name: name, timestamp: occurred_at.utc.iso8601(3), data: data }
  end
end
