# frozen_string_literal: true

# A short-lived, spend-capped OpenRouter key minted for one Pi spawn. See
# PiSessionKeys for the lifecycle.
#
# The row holds OpenRouter's identifier for the key (`key_hash`) and never the
# key itself: the plaintext exists in the create response, in the spawn
# environment of the one Pi process it was minted for, and nowhere else Zimmer
# writes. `usage_usd` is what OpenRouter reported the key had spent when it was
# revoked, which attributes Pi spend to a session without reading a transcript.
class PiProviderKey < ApplicationRecord
  # Why a key was revoked. Stored as a string so a row reads on its own.
  REVOKE_REASONS = %w[
    superseded
    session_at_rest
    session_gone
    expired
  ].freeze

  validates :key_hash, presence: true, uniqueness: true
  validates :name, presence: true
  validates :limit_usd, :expires_at, presence: true
  validates :revoke_reason, inclusion: { in: REVOKE_REASONS }, allow_nil: true

  scope :active, -> { where(revoked_at: nil) }

  def active? = revoked_at.nil?
end
