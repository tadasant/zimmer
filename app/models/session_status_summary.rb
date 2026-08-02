# frozen_string_literal: true

# The two-or-three sentence "where things stand" blurb shown in the Status panel
# at the top of a session's detail page, plus the bookkeeping that decides when
# it is allowed to be regenerated.
#
# The blurb itself is written by an agent — see SessionStatusSummaryGenerator,
# which forks the session and asks the fork to summarize the conversation it is
# already holding. This record is the durable half: what was written, how much
# transcript it was written from, and whether a generation is in flight.
#
# **Staleness is counted in transcript lines, not in time.** A summary does not
# go stale because an hour passed; it goes stale because the session said
# something new. `transcript_line_count` is the session's line count at the
# moment the displayed summary was produced, so `messages_since` is a plain
# subtraction — and a summary of a session that has not moved is never
# regenerated, no matter how many times the page is viewed.
class SessionStatusSummary < ApplicationRecord
  include ActionView::RecordIdentifier

  belongs_to :session
  belongs_to :fork_session, class_name: "Session", optional: true

  # Generation takes a whole agent turn on a fork, so the page that asked for it
  # is long since rendered by the time an answer exists. Without this the panel
  # sits on "Generating…" until someone reloads — which, for the one control in
  # the panel, reads as broken.
  after_commit :broadcast_panel_replacement, on: [ :create, :update ]

  STATES = %w[idle pending ready failed].freeze

  validates :state, inclusion: { in: STATES }

  # How long an in-flight generation may sit before a new request is allowed to
  # replace it. A fork that dies without ever reaching pause/fail would
  # otherwise wedge the panel in "generating…" forever, with the regenerate
  # button refusing to start a second attempt.
  PENDING_TIMEOUT = 15.minutes

  def ready? = state == "ready"
  def failed? = state == "failed"

  # A generation is only "pending" while it is plausibly still running. Past
  # PENDING_TIMEOUT the flag is treated as debris, not as a live attempt.
  def pending?
    state == "pending" && requested_at.present? && requested_at > PENDING_TIMEOUT.ago
  end

  # True when a generation was started and neither finished nor failed, but has
  # outlived PENDING_TIMEOUT — the panel says so rather than spinning forever.
  def abandoned?
    state == "pending" && !pending?
  end

  # Transcript lines the session has written since the displayed summary was
  # generated. Zero means the summary is current.
  #
  # Clamped at zero: a transcript can shrink (a fork's truncated copy, an
  # archive/restore that rewrites it), and "-3 messages since" is worse than
  # silence.
  def messages_since(current_line_count)
    [ current_line_count.to_i - transcript_line_count.to_i, 0 ].max
  end

  # Whether the session has moved since the displayed summary was written.
  def stale?(current_line_count)
    summary.blank? || messages_since(current_line_count).positive?
  end

  # A link to a message in THIS session's own transcript, written as an absolute
  # URL, collapsed to the bare fragment it actually is.
  #
  # The generating fork is told to write absolute URLs, because it has no way to
  # know where its answer will be rendered — and the host it uses can be stale by
  # the time anyone reads it (a moved deployment, a summary generated before
  # ZIMMER_*_BASE_URL was set). Matching on the path rather than the host means
  # such a link still lands on the page the reader is already looking at instead
  # of navigating away to a host that may not resolve.
  SELF_LINK = %r{https?://[^\s)\]]+/sessions/%<id>d\#(?<fragment>message-\d+)}
  private_constant :SELF_LINK

  def summary_markdown
    return summary if summary.blank?

    summary.gsub(Regexp.new(format(SELF_LINK.source, id: session_id)), '#\k<fragment>')
  end

  private

  # Re-renders the Status panel on the session detail screen (full page and
  # dashboard drawer alike — both subscribe to this stream). Best-effort, like
  # every other broadcast on this path: a rendering or cable failure must not
  # take down the job that produced the summary.
  def broadcast_panel_replacement
    broadcast_replace_to(
      "session_#{session_id}_status",
      target: "session_#{session_id}_status_panel",
      partial: "sessions/status_panel",
      locals: { agent_session: session }
    )
  rescue => e
    Rails.logger.error "[SessionStatusSummary] Broadcast failed for session #{session_id}: #{e.message}"
  end
end
