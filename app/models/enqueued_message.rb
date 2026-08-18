class EnqueuedMessage < ApplicationRecord
  # The statuses a queued message can hold.
  #
  # `pending` -> `processing` -> `sent` is the delivery path, and the row is
  # destroyed immediately after `sent` — so `sent` is a moment, not a resting
  # place. `undelivered` is the one terminal resting state: the session was
  # archived while this message was still queued, which ends every path by
  # which it could have been delivered.
  STATUSES = %w[pending processing sent undelivered].freeze

  belongs_to :session

  # Validations
  validates :content, presence: true, length: { maximum: Session::PROMPT_MAX_LENGTH, message: "is too long (maximum #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters)" }
  validates :goal, length: { maximum: Session::GOAL_MAX_LENGTH, message: "is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters)" }, allow_nil: true
  validates :position, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :status, inclusion: { in: STATUSES, message: "%{value} is not a valid status" }

  # Scopes
  scope :pending, -> { where(status: "pending") }
  scope :undelivered, -> { where(status: "undelivered") }
  scope :ordered, -> { order(position: :asc) }

  # Mark message as sent
  def mark_as_sent!
    update!(status: "sent")
  end

  # Retire a message that will never be delivered.
  #
  # Called from the `archive` transition, which is the point at which delivery
  # becomes impossible: Session#process_next_enqueued_message! only claims
  # `pending` rows, and the only caller that claims them for a live session is
  # AgentSessionJob's end-of-turn drain, which an archived session never
  # reaches. Leaving the row `pending` after that is what made the loss silent —
  # every reader of the queue (the panel, the REST index, the MCP list) treats
  # `pending` as "still going to be sent".
  #
  # The row is kept rather than destroyed. Its content is the thing the sender
  # was promised delivery of, so it stays readable through the same surfaces
  # that reported it queued.
  def mark_undelivered!
    update!(status: "undelivered")
  end

  # Reorder message to a new position
  # Updates positions of other messages in the same session to maintain sequential ordering
  # Uses a temporary position (0) to avoid unique constraint violations during swap
  #
  # Unlike the bulk decrement on the DELETE paths, this method does not rely on
  # the query planner, or on the deferred unique constraint: it parks the moving
  # row at 0, then shifts its neighbours one row per statement in an order Ruby
  # pins explicitly (ascending when moving down, descending when moving up), so
  # every write lands on a position no row still holds.
  def reorder_to(new_position)
    return if new_position == position

    transaction do
      old_position = position

      # Move current message to temporary position (0) to avoid unique constraint violation
      update_column(:position, 0)

      if new_position > old_position
        # Moving down: shift messages between old and new position up
        session.enqueued_messages
               .where("position > ? AND position <= ?", old_position, new_position)
               .order(position: :asc)
               .each { |msg| msg.update_column(:position, msg.position - 1) }
      else
        # Moving up: shift messages between new and old position down
        session.enqueued_messages
               .where("position >= ? AND position < ?", new_position, old_position)
               .order(position: :desc)
               .each { |msg| msg.update_column(:position, msg.position + 1) }
      end

      # Move to final position
      update_column(:position, new_position)
    end
  end
end
