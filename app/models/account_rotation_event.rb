# frozen_string_literal: true

# One movement of a runtime's account pool: the pool was on `rotated_from` and is
# now on `rotated_to`.
#
# The event outlives both accounts. Deleting a ClaudeAccount nullifies the
# pointing foreign keys rather than destroying the event, because a rotation that
# vanishes when its target is deleted takes the record of *why* the pool moved
# with it — and a rotation whose source silently becomes nil reads as if the pool
# came from nowhere.
#
# `rotated_from_email` / `rotated_to_email` are captured at write time so a
# nulled pointer still names an account, and they are what distinguishes the two
# meanings a nil `rotated_from_id` would otherwise share: no source at all (a
# bootstrap, or a manual activation with nothing current) versus a source that
# has since been deleted.
#
# `runtime` is denormalized for the same reason. /quotas scopes its rotation
# table to one runtime, and it could only do that by joining to an account that
# still exists — so an event whose target was deleted would drop off the page it
# exists to inform.
class AccountRotationEvent < ApplicationRecord
  belongs_to :rotated_from, class_name: "ClaudeAccount", optional: true
  belongs_to :rotated_to, class_name: "ClaudeAccount", optional: true

  validates :source, presence: true, inclusion: { in: %w[automatic manual] }

  # Required to create, allowed to become nil later — a target-less event is only
  # ever the residue of a deleted account.
  validates :rotated_to, presence: true, on: :create

  # The one filter /quotas applies to this table. Always derivable at create time
  # (rotated_to is required), and validated so that stays true: an event with no
  # runtime would silently vanish from the page it exists to inform.
  validates :runtime, presence: true, on: :create

  before_validation :capture_account_identity, on: :create

  scope :recent, -> { order(created_at: :desc).limit(50) }
  scope :for_runtime, ->(runtime) { where(runtime: runtime) }

  # The account the pool moved away from, whether or not it still exists. nil
  # when there genuinely was no source.
  def from_email
    rotated_from&.email || rotated_from_email
  end

  # The account the pool moved to, whether or not it still exists.
  def to_email
    rotated_to&.email || rotated_to_email
  end

  # The source account existed and has since been deleted — as opposed to there
  # having been no source, which is what a nil `from_email` means.
  def from_deleted?
    rotated_from_id.nil? && rotated_from_email.present?
  end

  # The target account has since been deleted.
  def to_deleted?
    rotated_to_id.nil?
  end

  private

  def capture_account_identity
    self.rotated_from_email ||= rotated_from&.email
    self.rotated_to_email ||= rotated_to&.email
    self.runtime ||= rotated_to&.runtime || rotated_from&.runtime
  end
end
