class EnqueuedMessage < ApplicationRecord
  belongs_to :session

  # Validations
  validates :content, presence: true, length: { maximum: Session::PROMPT_MAX_LENGTH, message: "is too long (maximum #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters)" }
  validates :goal, length: { maximum: Session::GOAL_MAX_LENGTH, message: "is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters)" }, allow_nil: true
  validates :position, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :status, inclusion: { in: %w[pending processing sent], message: "%{value} is not a valid status" }

  # Scopes
  scope :pending, -> { where(status: "pending") }
  scope :ordered, -> { order(position: :asc) }

  # Mark message as sent
  def mark_as_sent!
    update!(status: "sent")
  end

  # Reorder message to a new position
  # Updates positions of other messages in the same session to maintain sequential ordering
  # Uses a temporary position (0) to avoid unique constraint violations during swap
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
