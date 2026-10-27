# frozen_string_literal: true

# CarPlay fit — can the next thing this session needs from a human be done by
# voice from a car, or does it need a laptop?
#
# This is the axis a driver triages on. About half the sessions parked in
# `needs_input` on a typical board want a credential pasted into a console, a
# test run on a Mac, or a long document read; the rest want a yes or no, a merge
# decision, or a short reply. Without this mark the two halves look alike from a
# car, and every drive re-triages the same laptop-only rows from scratch.
#
# **It is a judgement with provenance, not a tag.** Five columns travel together:
#
# - `carplay_fit`            — the decision: `carplay_ok`, `laptop_only`, or NULL
#                              (untagged)
# - `carplay_fit_reason`     — why: what kind of human action the session is
#                              waiting on
# - `carplay_fit_source`     — who wrote it: `auto` (the status-summary fork at
#                              rest), `human` (the UI), `assistant` (Live Mode
#                              or another MCP client), or `session` (a session
#                              about itself)
# - `carplay_fit_set_at`     — when
# - `carplay_fit_line_count` — the session's `transcript_line_count` when the
#                              mark was written
#
# **Staleness is counted in transcript lines, not in time** — the same model
# SessionStatusSummary uses. A mark is CURRENT while the session has not written
# a line past `carplay_fit_line_count`, and STALE once it has: a session that
# became laptop-only after opening a PR that needs a diff read has moved, and
# the mark written before that move is about an earlier state. Every filter
# here treats a stale mark as untagged, and every summary names it as stale.
# When the session next comes to rest, the status-summary fork writes a fresh
# `auto` mark (SessionStatusSummaryGenerator::CARPLAY_FIT_TRAILER_RULE).
#
# **Precedence between writers**, enforced by Sessions::SetCarplayFit: at the
# same transcript position a `human` mark beats `assistant` and `session`, which
# beat `auto`. A mark written against a LATER position always wins, whoever
# wrote it, because every earlier mark was about an earlier state.
#
# **It decides nothing.** Nothing in the scheduler, the spot queue, precedence,
# the quota gate, triggers or the state machine reads these columns, and the
# board's order is untouched: a laptop-only session keeps its place for the
# laptop. The mark changes which rows a caller asks for, never when anything
# runs. That is the contract `visibility` has, and it is the one to keep.
module SessionCarplayFit
  extend ActiveSupport::Concern

  CARPLAY_OK = "carplay_ok"
  LAPTOP_ONLY = "laptop_only"
  FITS = [ CARPLAY_OK, LAPTOP_ONLY ].freeze

  # What the session is waiting on a human for. The `carplay_ok` reasons come
  # first, then the `laptop_only` ones; `nothing_needed` is the honest answer for
  # a session that came to rest needing nobody.
  REASON_DECISION = "decision"
  REASON_SHORT_ANSWER = "short_answer"
  REASON_LONG_READ = "long_read"
  REASON_MANUAL_STEPS = "manual_steps"
  REASON_CREDENTIAL = "credential"
  REASON_LOCAL_DEVICE = "local_device"
  REASON_NOTHING_NEEDED = "nothing_needed"
  REASONS = [
    REASON_DECISION, REASON_SHORT_ANSWER, REASON_LONG_READ,
    REASON_MANUAL_STEPS, REASON_CREDENTIAL, REASON_LOCAL_DEVICE,
    REASON_NOTHING_NEEDED
  ].freeze

  SOURCE_AUTO = "auto"
  SOURCE_HUMAN = "human"
  SOURCE_ASSISTANT = "assistant"
  SOURCE_SESSION = "session"
  SOURCES = [ SOURCE_AUTO, SOURCE_HUMAN, SOURCE_ASSISTANT, SOURCE_SESSION ].freeze

  # Who outranks whom at the same transcript position. `assistant` and `session`
  # tie: an agent reading the summary and the session reading its own state are
  # the same quality of judgement, and either may correct the other.
  SOURCE_RANK = {
    SOURCE_AUTO => 0,
    SOURCE_SESSION => 1,
    SOURCE_ASSISTANT => 1,
    SOURCE_HUMAN => 2
  }.freeze

  # How a listing may narrow on this axis. They live here rather than on a
  # controller because every surface filters on them — the dashboard, the REST
  # listings, `quick_search_sessions` and `get_user_view` — and an MCP tool
  # should not have to autoload a web controller to name a filter value.
  #
  # `not_laptop_only` is the one a driver wants: verified good, plus not yet
  # judged. A stale mark counts as untagged on every option.
  FILTER_CARPLAY_OK = "carplay_ok"
  FILTER_LAPTOP_ONLY = "laptop_only"
  FILTER_UNTAGGED = "untagged"
  FILTER_NOT_LAPTOP_ONLY = "not_laptop_only"
  FILTER_OPTIONS = [ FILTER_CARPLAY_OK, FILTER_LAPTOP_ONLY, FILTER_UNTAGGED, FILTER_NOT_LAPTOP_ONLY ].freeze

  LABELS = {
    CARPLAY_OK => "CarPlay-ok",
    LAPTOP_ONLY => "Laptop only"
  }.freeze

  REASON_LABELS = {
    REASON_DECISION => "a decision",
    REASON_SHORT_ANSWER => "a short answer",
    REASON_LONG_READ => "a long read",
    REASON_MANUAL_STEPS => "manual steps",
    REASON_CREDENTIAL => "a credential",
    REASON_LOCAL_DEVICE => "a local device",
    REASON_NOTHING_NEEDED => "nothing"
  }.freeze

  # A mark is current while the session has not written a line past the one it
  # was written against. Spelled once, as SQL, so the scopes and the predicate
  # below cannot drift.
  CURRENT_SQL = "(sessions.carplay_fit IS NOT NULL AND sessions.carplay_fit_line_count IS NOT NULL " \
                "AND sessions.carplay_fit_line_count >= sessions.transcript_line_count)"
  private_constant :CURRENT_SQL

  included do
    validates :carplay_fit, inclusion: { in: FITS, message: "%{value} is not a valid CarPlay fit" }, allow_nil: true
    validates :carplay_fit_reason, inclusion: { in: REASONS, message: "%{value} is not a valid CarPlay fit reason" }, allow_nil: true
    validates :carplay_fit_source, inclusion: { in: SOURCES, message: "%{value} is not a valid CarPlay fit source" }, allow_nil: true

    # Sessions whose mark is current, whatever it says.
    scope :carplay_fit_current, -> { where(CURRENT_SQL) }

    # The complement: never marked, or marked against an earlier transcript.
    scope :carplay_fit_untagged, -> { where("NOT #{CURRENT_SQL}") }

    # One listing filter, by its option name. An unknown option narrows nothing,
    # the way the REST listings treat every non-strict filter.
    scope :carplay_fit_filter, ->(option) {
      case option.to_s
      when FILTER_CARPLAY_OK then carplay_fit_current.where(carplay_fit: CARPLAY_OK)
      when FILTER_LAPTOP_ONLY then carplay_fit_current.where(carplay_fit: LAPTOP_ONLY)
      when FILTER_UNTAGGED then carplay_fit_untagged
      when FILTER_NOT_LAPTOP_ONLY
        where("NOT (#{CURRENT_SQL} AND sessions.carplay_fit = ?)", LAPTOP_ONLY)
      else all
      end
    }
  end

  # The row-level counterpart of `carplay_fit_current`; keep the two answering
  # identically.
  def carplay_fit_current?
    carplay_fit.present? && !carplay_fit_line_count.nil? && carplay_fit_line_count >= transcript_line_count.to_i
  end

  # The mark as every read surface should treat it: the stored value while it is
  # current, nil once the session has moved past it.
  def effective_carplay_fit
    carplay_fit_current? ? carplay_fit : nil
  end

  # Transcript lines written since the mark. Zero while it is current.
  def carplay_fit_messages_since
    return 0 if carplay_fit.blank? || carplay_fit_line_count.nil?

    [ transcript_line_count.to_i - carplay_fit_line_count, 0 ].max
  end

  # One line of English for the card chip, the API and the MCP listings. nil
  # when the session carries no mark at all, so callers can render it or not
  # without a second predicate. A stale mark is still described — a reader
  # deciding whether to trust it wants to know it was there and that it is old.
  #
  #   "CarPlay-ok (a decision) · auto · current"
  #   "Laptop only (a credential) · human · stale, 4 message(s) since"
  def carplay_fit_summary
    return nil if carplay_fit.blank?

    parts = [ LABELS.fetch(carplay_fit, carplay_fit) ]
    parts[0] = "#{parts[0]} (#{REASON_LABELS.fetch(carplay_fit_reason, carplay_fit_reason)})" if carplay_fit_reason.present?
    parts << carplay_fit_source if carplay_fit_source.present?
    parts << (carplay_fit_current? ? "current" : "stale, #{carplay_fit_messages_since} message(s) since")
    parts.join(" · ")
  end

  def carplay_fit_label
    LABELS[carplay_fit]
  end
end
