# frozen_string_literal: true

class AccountRotationEvent < ApplicationRecord
  belongs_to :rotated_from, class_name: "ClaudeAccount", optional: true
  belongs_to :rotated_to, class_name: "ClaudeAccount"

  validates :source, presence: true, inclusion: { in: %w[automatic manual] }
  validates :rotated_to, presence: true

  scope :recent, -> { order(created_at: :desc).limit(50) }
end
