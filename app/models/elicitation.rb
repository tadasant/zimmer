# frozen_string_literal: true

# Represents an MCP server fallback elicitation request.
#
# When an MCP server needs user confirmation before performing a sensitive action
# (e.g., sending an email) and the MCP client doesn't support native elicitation,
# the server falls back to HTTP endpoints. This model stores those requests and
# tracks their lifecycle.
#
# Lifecycle: pending -> accept | decline | cancel | expired
#
# Attributes:
#   session_id        - The Zimmer session this elicitation relates to
#   request_id        - Unique ID from the MCP server (for polling)
#   status            - Current state: pending, accept, decline, cancel, expired
#   mode              - Elicitation mode (currently "form")
#   message           - Human-readable explanation from the MCP server
#   requested_schema  - JSON Schema defining response format (form fields)
#   meta              - Full _meta object from the POST request (passthrough)
#   tool_name         - Which MCP tool triggered this (com.pulsemcp/tool-name)
#   context           - Free-text LLM explanation (com.pulsemcp/context)
#   mcp_session_id    - Calling agent session identifier (com.pulsemcp/session-id)
#   expires_at        - When this elicitation expires
#   response_content  - User's form response content (filled-in fields)
#   responded_at      - When the user responded
class Elicitation < ApplicationRecord
  DEFAULT_EXPIRATION = 10.minutes

  STATUSES = %w[pending accept decline cancel expired].freeze
  RESOLVE_ACTIONS = %w[accept decline].freeze
  MODES = %w[form].freeze

  belongs_to :session

  validates :request_id, presence: true, uniqueness: true
  validates :mode, presence: true, inclusion: { in: MODES }
  validates :message, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }
  scope :active, -> { pending.where("expires_at > ?", Time.current) }
  scope :expired_pending, -> { pending.where("expires_at <= ?", Time.current) }
  scope :for_session, ->(session) { where(session: session) }

  # Keep the owning session's status in sync with its active elicitations.
  #
  # A running session blocked on a pending elicitation should surface as
  # needs_input (so it appears in the user's homepage action queue and gets the
  # same Slack / push visibility a normal pause gets) WITHOUT killing the live
  # agent process. When the last active elicitation is resolved or expires, the
  # session flips back to running.
  #
  # The reconciliation lives on the session (`sync_elicitation_blocking_state!`)
  # and is idempotent, so firing it on every create and update — across all paths
  # (API create, web resolve, API-poll expiry, model expire, cleanup job) — keeps
  # the invariant without scattering state-machine calls. The only updates an
  # elicitation receives are status transitions (resolve/expire), so an ungated
  # after_commit is sufficient; a single `after_commit ... on: [:create, :update]`
  # is used rather than separate after_create_commit/after_update_commit hooks
  # because Rails dedupes same-named commit callbacks into one entry.
  after_commit :sync_session_elicitation_state, on: [ :create, :update ]

  def pending?
    status == "pending"
  end

  def resolved?
    !pending?
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  # Resolve with user's response
  # @param action [String] "accept" or "decline"
  # @param content [Hash, nil] Form field values
  def resolve!(action:, content: nil)
    raise "Cannot resolve a non-pending elicitation" unless pending?
    raise ArgumentError, "Invalid action: #{action}. Must be one of: #{RESOLVE_ACTIONS.join(', ')}" unless RESOLVE_ACTIONS.include?(action)

    update!(
      status: action,
      response_content: content,
      responded_at: Time.current
    )
  end

  # Check and expire if past expiration time
  def expire_if_needed!
    return unless pending? && expired?

    update!(status: "expired", responded_at: Time.current)
  end

  # Build API response hash for the poll endpoint
  # @return [Hash] Response conforming to the elicitation poll spec
  def to_poll_response
    {
      action: resolved? ? status : "pending",
      content: resolved? ? response_content : nil,
      _meta: build_response_meta
    }
  end

  private

  # Reconcile the owning session's blocking state. Reloads the association so the
  # session reflects this elicitation's just-committed status change before the
  # scope-based check in sync_elicitation_blocking_state! runs.
  def sync_session_elicitation_state
    session.sync_elicitation_blocking_state!
  rescue => e
    Rails.logger.error "[Elicitation] Failed to sync session #{session_id} blocking state: #{e.message}"
  end

  def build_response_meta
    response_meta = {
      "com.pulsemcp/request-id" => request_id
    }
    if resolved?
      response_meta["com.pulsemcp/responded-at"] = responded_at&.iso8601
    end
    response_meta
  end
end
