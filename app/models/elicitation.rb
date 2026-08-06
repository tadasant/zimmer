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
# accept / decline / cancel are human (or programmatic) answers: accept and
# decline answer the question, cancel dismisses it without answering. `expired`
# is the clock answering instead of a person.
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
  # The built-in expiry window, used when the operator has set no default and the
  # MCP server named no deadline of its own. An hour, not the ten minutes this
  # used to be: the whole point of the feature is to tolerate a human who is away
  # from the desk, and a ten-minute fuse fails exactly the case it exists for.
  DEFAULT_EXPIRATION = 60.minutes

  # Operator-set default, in minutes. Deploy-level policy, so it lives alongside
  # Zimmer's other timeout knobs (PROCESS_*, GIT_CLONE_TIMEOUT_SECONDS) rather
  # than in the settings UI: it describes how long this instance is willing to
  # hold an agent process open, not something to retune per session.
  EXPIRATION_ENV_VAR = "ELICITATION_EXPIRATION_MINUTES"

  # Bounds on the operator value. The floor keeps a typo (or a 0) from creating
  # elicitations that are born expired; the ceiling keeps one from pinning an
  # agent process open for a month. A value outside them is clamped, not
  # rejected — a deploy must not fail over a knob.
  MIN_EXPIRATION = 1.minute
  MAX_EXPIRATION = 7.days

  STATUSES = %w[pending accept decline cancel expired].freeze

  # Every action that takes a pending elicitation to a resolved one. `cancel` is
  # the protocol's "the user dismissed this without answering" — Zimmer offers it
  # on all three response surfaces (web banner, REST, MCP tool) so a request the
  # user does not want to answer ends in a real, poll-visible outcome instead of
  # sitting until it expires.
  RESOLVE_ACTIONS = %w[accept decline cancel].freeze

  # Only an accept carries the form payload the schema asked for. A decline or a
  # cancel answers nothing, so any content sent with one is dropped rather than
  # stored and later replayed to the MCP server as if it were an answer.
  CONTENT_BEARING_ACTIONS = %w[accept].freeze

  MODES = %w[form].freeze

  belongs_to :session

  validates :request_id, presence: true, uniqueness: true
  validates :mode, presence: true, inclusion: { in: MODES }
  validates :message, presence: true
  validates :status, inclusion: { in: STATUSES }

  # An elicitation with no expiry is invisible to both the `active` and the
  # `expired_pending` scope: it never blocks its session and nothing ever expires
  # it. Defaulting here (rather than in the API controller alone) means every
  # creation path — API, console, dashboard, test — gets a deadline.
  before_validation :apply_default_expiration, on: :create

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

  # How long a new elicitation lives when nobody more specific said otherwise.
  #
  # Precedence for the deadline on a given request, highest first:
  #   1. the MCP server's own `_meta["com.pulsemcp/expires-at"]` (per request)
  #   2. ELICITATION_EXPIRATION_MINUTES (this instance's operator)
  #   3. DEFAULT_EXPIRATION (the built-in hour)
  #
  # Read per call rather than frozen into a constant at load, so a worker picks
  # the value up from its environment without a code change, and so tests can
  # exercise the precedence without reloading the class.
  #
  # @return [ActiveSupport::Duration]
  def self.default_expiration
    raw = ENV[EXPIRATION_ENV_VAR]
    return DEFAULT_EXPIRATION if raw.blank?

    minutes = Integer(raw, exception: false)
    if minutes.nil? || minutes <= 0
      Rails.logger.warn "[Elicitation] Ignoring #{EXPIRATION_ENV_VAR}=#{raw.inspect} (expected a positive integer number of minutes); using #{DEFAULT_EXPIRATION.inspect}"
      return DEFAULT_EXPIRATION
    end

    requested = minutes.minutes
    # Compared and returned as Durations rather than clamped: ActiveSupport::Duration
    # has no #clamp of its own, so Comparable's would hand back the raw second count
    # for an in-range value and a Duration for an out-of-range one.
    return requested if requested >= MIN_EXPIRATION && requested <= MAX_EXPIRATION

    clamped = (requested < MIN_EXPIRATION) ? MIN_EXPIRATION : MAX_EXPIRATION
    Rails.logger.warn "[Elicitation] Clamped #{EXPIRATION_ENV_VAR}=#{raw.inspect} to #{clamped.inspect} (allowed range: #{MIN_EXPIRATION.inspect}..#{MAX_EXPIRATION.inspect})"
    clamped
  end

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
  # @param action [String] "accept", "decline", or "cancel"
  # @param content [Hash, nil] Form field values (kept only for "accept")
  def resolve!(action:, content: nil)
    raise "Cannot resolve a non-pending elicitation" unless pending?
    raise ArgumentError, "Invalid action: #{action}. Must be one of: #{RESOLVE_ACTIONS.join(', ')}" unless RESOLVE_ACTIONS.include?(action)

    update!(
      status: action,
      response_content: CONTENT_BEARING_ACTIONS.include?(action) ? content : nil,
      responded_at: Time.current
    )
  end

  # Check and expire if past expiration time
  def expire_if_needed!
    return unless pending? && expired?

    update!(status: "expired", responded_at: Time.current)
  end

  # A one-line description of this request, for the banner Zimmer shows when the
  # round-trip ends without a human answer.
  def summary
    tool_name.present? ? "#{tool_name}: #{message}" : message.to_s
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
  #
  # An expiry is recorded on the session AFTER the sync, not before: the sync's
  # unblock clears the lost-elicitation marker (a resolved round-trip is not a
  # lost one), so recording first would have that clear wipe it straight back off.
  def sync_session_elicitation_state
    session.sync_elicitation_blocking_state!
    session.record_lost_elicitation!(reason: "expired", elicitation: self) if status == "expired"
  rescue => e
    Rails.logger.error "[Elicitation] Failed to sync session #{session_id} blocking state: #{e.message}"
  end

  # Default the deadline when the creator named none. Uses the same resolution
  # every other path uses, so the operator's window applies here too.
  def apply_default_expiration
    self.expires_at ||= self.class.default_expiration.from_now
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
