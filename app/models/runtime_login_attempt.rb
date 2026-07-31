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

  # How long a non-terminal attempt may go without RuntimeLoginJob stamping
  # heartbeat_at before we declare the worker driving it gone. The job beats
  # every RuntimeLoginJob::HEARTBEAT_INTERVAL (15s), so this leaves several
  # missed beats of slack for a busy worker or a slow DB.
  HEARTBEAT_TIMEOUT = 90.seconds

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

  # The job that was driving this attempt has stopped stamping its heartbeat, so
  # nothing is holding the login CLI open any more. A nil heartbeat is NOT stalled
  # — it means the job hasn't dequeued yet (the row is created by the web
  # container, the job runs in the worker), and that case is bounded by
  # expired_window? instead.
  def stalled?
    !terminal? && heartbeat_at.present? && heartbeat_at < HEARTBEAT_TIMEOUT.ago
  end

  # A non-terminal attempt nothing will ever advance again: its verification
  # window elapsed, or the worker driving it went away. Both must resolve to a
  # terminal state or the Quotas panel polls a spinner forever.
  def orphaned?
    !terminal? && (expired_window? || stalled?)
  end

  # Drive an orphaned attempt to its terminal state, naming what actually timed
  # out so the panel can tell the user something actionable instead of stopping
  # at a spinner. Also drops the pasted authorization code, which is
  # credential-adjacent and single-use.
  #
  # An elapsed window is "expired" (the user ran out of time); a dead worker is
  # "failed" (Zimmer ran out of worker). Both are terminal, so both stop the
  # poller.
  def fail_orphaned!
    return false unless orphaned?

    if stalled?
      update!(
        status: "failed",
        error_message: "The worker running this login stopped responding " \
                       "(no heartbeat for over #{HEARTBEAT_TIMEOUT.inspect}). Start a new login.",
        pasted_code: nil
      )
    else
      update!(
        status: "expired",
        error_message: "Login window expired before completion. Start a new login.",
        pasted_code: nil
      )
    end
    true
  end

  # The single reader for the UI → worker side of the cross-container bus
  # (pasted authorization code + cancellation), owning the `uncached` block so no
  # call site can forget it.
  #
  # RuntimeLoginJob polls this row from the worker while the *web* container
  # writes to it. Both run inside a query-cache scope where the cache is
  # pool-level (Rails 7.1+), and the poll issues identical SQL every tick — so
  # the first read would cache pasted_code=nil and every later read would be
  # served from that cache, never observing the user's write. uncached forces a
  # fresh DB hit. See github.com/tadasant/zimmer/issues/111.
  #
  # Returns [status, pasted_code], or nil when the row is gone.
  def self.bus_state(id)
    uncached { where(id: id).pick(:status, :pasted_code) }
  end

  private

  def set_defaults
    self.status ||= "starting"
    self.expires_at ||= Time.current + DEFAULT_TTL
  end
end
