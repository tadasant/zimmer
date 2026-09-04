# frozen_string_literal: true

# One write Zimmer made — or tried to make — to the Parameter Store.
#
# Rows are append-only and hold no secret value. `fingerprint` is a truncated
# SHA-256 digest, which is what lets the Inference page say "the key in the store
# is the one you think it is" without ever rendering a character of it.
#
# Failed attempts are recorded too. A Save that 403s is exactly the event a
# human comes back to this page to understand, and a table that only remembers
# successes cannot tell them apart from a Save that never happened.
class ManagedSecretWrite < ApplicationRecord
  CREATED = "created"
  DELETED = "deleted"
  ACTIONS = [ CREATED, DELETED ].freeze

  SUCCEEDED = "succeeded"
  FAILED = "failed"
  OUTCOMES = [ SUCCEEDED, FAILED ].freeze

  validates :variable, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :outcome, inclusion: { in: OUTCOMES }

  scope :for_variable, ->(variable) { where(variable: variable) }
  scope :succeeded, -> { where(outcome: SUCCEEDED) }

  # The last write of `variable` that actually landed, or nil.
  def self.last_success(variable)
    for_variable(variable).succeeded.order(created_at: :desc).first
  end

  def succeeded? = outcome == SUCCEEDED
end
