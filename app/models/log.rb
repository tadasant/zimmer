class Log < ApplicationRecord
  belongs_to :session

  # Validations
  validates :content, presence: true
  validates :level, inclusion: { in: %w[info error debug warning verbose], message: "%{value} is not a valid log level" }

  # Turbo Stream broadcasting
  after_create_commit -> { broadcast_append_to_timeline }

  private

  def broadcast_append_to_timeline
    timeline_item = {
      type: "log",
      level: level,
      content: content,
      timestamp: created_at,
      sort_time: created_at
    }

    broadcast_append_to(
      "session_#{session_id}_timeline",
      partial: "timeline_items/item",
      locals: { item: timeline_item },
      target: "session_#{session_id}_timeline"
    )
  end
end
