# frozen_string_literal: true

# One thing that came back from work a Live conversation started, on its way to
# being said (LiveConversations::BackgroundResults, which owns every write).
#
#   waiting → offered (claimed for an answer or a call, and on the thread)
#           → delivered (a call's model has it) → raised (the assistant has
#   answered the person since) ; or dropped, with why.
class LiveBackgroundResult < ApplicationRecord
  KINDS = %w[message needs_input finished failed].freeze
  # A result nobody came back for is old news, and the session is on the board.
  EXPIRES_AFTER = 24.hours
  MESSAGE_LIMIT = 2_000

  belongs_to :live_conversation
  belongs_to :session

  validates :kind, inclusion: { in: KINDS }
  validates :event_id, presence: true

  scope :unsaid, -> { where(raised_at: nil, dropped_at: nil) }

  def drop!(reason) = update!(dropped_at: Time.current, drop_reason: reason.to_s.truncate(120))
end
