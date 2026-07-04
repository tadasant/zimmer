# frozen_string_literal: true

# Tracks one in-flight UI-driven login ("Authenticate" button on the Quotas
# screen) for a ClaudeAccount. See CreateRuntimeLoginAttempts for the role this
# row plays as the cross-container message bus between the web controller and
# the RuntimeLoginJob running in the worker.
#
# Status lifecycle:
#   starting      -> job enqueued, CLI not yet spawned
#   awaiting_user -> verification URL (and Codex code) surfaced; waiting on the
#                    user to authorize in their browser
#   awaiting_code -> (Claude only) CLI is asking for the pasted authorization
#                    code; waiting on submit_login_code
#   completing    -> user input received; CLI is exchanging/finalizing tokens
#   succeeded     -> tokens captured into the account
#   failed        -> CLI errored or token capture failed (see error_message)
#   canceled      -> user canceled, or a newer attempt superseded this one
#   expired       -> verification window elapsed before completion
class RuntimeLoginAttempt < ApplicationRecord
  belongs_to :claude_account

  STATUSES = %w[
    starting awaiting_user awaiting_code completing
    succeeded failed canceled expired
  ].freeze

  TERMINAL_STATUSES = %w[succeeded failed canceled expired].freeze

  # Codex device codes expire after 15 minutes; keep our window comfortably
  # under that so we fail with a clear "expired" rather than a CLI error.
  DEFAULT_TTL = 14.minutes

  validates :runtime, presence: true, inclusion: { in: ClaudeAccount::RUNTIMES }
  validates :status, presence: true, inclusion: { in: STATUSES }

  before_validation :set_defaults, on: :create

  scope :active, -> { where.not(status: TERMINAL_STATUSES) }

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def canceled?
    status == "canceled"
  end

  def succeeded?
    status == "succeeded"
  end

  def expired_window?
    expires_at.present? && Time.current > expires_at
  end

  private

  def set_defaults
    self.status ||= "starting"
    self.expires_at ||= Time.current + DEFAULT_TTL
  end
end
