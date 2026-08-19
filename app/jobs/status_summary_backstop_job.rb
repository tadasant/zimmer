# frozen_string_literal: true

# Re-runs a status-summary generation that never landed, for a session that has
# already come to rest.
#
# **Why this exists.** The one automatic trigger for the Status blurb is the
# session changing status — SessionStateMachine#enqueue_status_summary_refresh,
# on `pause` and on `fail`. That is the right trigger, and it stays the only
# thing that starts work for a session whose summary is fine. What it cannot do
# is recover: a session sitting in `needs_input` has no further transition, so a
# generation that was lost — the job discarded during a deploy, the fork parked
# out of quota, the claim abandoned past PENDING_TIMEOUT, the fork's answer
# arriving already behind the conversation — leaves the panel describing an
# earlier point in the session for as long as the session sits in the user's
# action queue. That queue is exactly where an accurate "where things stand"
# matters most.
#
# **This is a repair sweep, not polling.** It only looks at sessions that are AT
# REST and whose last generation demonstrably did not land, it never forces (so a
# summary the generator considers current still costs nothing), and it stamps
# `backstop_attempted_at` on every session it examines, so each one is looked at
# once per RETRY_INTERVAL rather than once per sweep. Rendering the panel still
# generates nothing.
#
# **It stands down during an auth outage.** A quota-exhausted pool is the single
# biggest producer of the failures this sweep repairs, and re-forking into an
# empty pool produces one more parked fork holding one more clone copy. So a
# runtime with no available account is skipped until the pool recovers.
class StatusSummaryBackstopJob < ApplicationJob
  queue_as :default

  # Sessions repaired per sweep. Each repair costs a fork of a repository and an
  # agent turn, so the cap is what keeps a bad day — a fleet-wide outage that
  # failed every generation at once — from becoming a fleet-wide re-fork. In
  # steady state it is zero: a session drops out of the candidate set as soon as
  # its summary lands.
  MAX_PER_SWEEP = 5

  # How long to leave a session alone after examining it. Longer than
  # SessionStatusSummary::PENDING_TIMEOUT so an in-flight generation is never
  # raced by the next sweep, and long enough that a session which can never be
  # summarized — one whose clone has been reclaimed — costs one refused enqueue
  # per half hour rather than one per sweep.
  RETRY_INTERVAL = 30.minutes

  def perform
    repaired = 0
    held_for_outage = 0

    candidates.each do |session|
      break if repaired >= MAX_PER_SWEEP
      next if session.blocked_on_elicitation?

      record = SessionStatusSummary.find_by(session_id: session.id)
      next unless due?(record)

      # An outage is checked BEFORE the session is stamped, so a sweep that
      # stands down does not also cost every session it skipped its retry
      # interval — the next sweep after the pool recovers picks them all up.
      if pool_exhausted?(session.agent_runtime)
        held_for_outage += 1
        next
      end

      stamp_examined(session, record)
      next unless needs_repair?(session, record)

      SessionStatusSummaryJob.perform_later(session.id)
      repaired += 1
    end

    return if repaired.zero? && held_for_outage.zero?

    Rails.logger.info(
      "[StatusSummaryBackstopJob] enqueued=#{repaired} held_for_auth_outage=#{held_for_outage}"
    )
  end

  private

  # Sessions at rest, most recently active first — the order the user's action
  # queue is read in, so the cap spends itself on the sessions most likely to be
  # opened next.
  #
  # `blocked_on_elicitation` sessions are dropped by the caller: they are
  # `needs_input` with a live agent process waiting on an approval mid-turn,
  # which is not a session at rest and not a conversation there is anything final
  # to say about yet.
  #
  # `transcript` is left out of the SELECT. It is by far the largest column in
  # the schema — megabytes on a long session — and this scan runs every five
  # minutes over every session in the action queue. Only #needs_repair? needs it,
  # and only for a session that is due to be examined at all, which the stamp
  # holds to once per RETRY_INTERVAL.
  def candidates
    Session
      .excluding_status_summary_forks
      .where(status: [ :needs_input, :failed ])
      .select(Session.column_names - [ "transcript" ])
      .order(updated_at: :desc)
  end

  # Whether this session is due to be looked at again. A record that does not
  # exist yet has never been looked at; a `pending` one has a generation in
  # flight and is not this sweep's business.
  def due?(record)
    return true if record.nil?
    return false if record.pending?

    record.backstop_attempted_at.nil? || record.backstop_attempted_at < RETRY_INTERVAL.ago
  end

  # Whether the last generation failed to leave a current summary behind.
  #
  # A session with no transcript is refused first, for the same reason
  # SessionStateMachine#enqueue_status_summary_refresh refuses it: there is
  # nothing to summarize, so the generator would decline and the sweep would have
  # spent a slot learning that.
  def needs_repair?(session, record)
    line_count = Session.transcript_line_count(transcript_of(session))
    return false if line_count.zero?
    return true if record.nil? || record.summary.blank?
    return true if record.failed? || record.abandoned?

    record.stale?(line_count)
  end

  # The one column #candidates deliberately did not select, fetched for the
  # single row that needs it.
  def transcript_of(session) = Session.where(id: session.id).pick(:transcript)

  # Whether the runtime's login pool has nothing left to run a fork on.
  # Memoized per sweep: one query per distinct runtime, not one per session.
  def pool_exhausted?(runtime)
    @pool_exhausted ||= {}
    return @pool_exhausted[runtime] if @pool_exhausted.key?(runtime)

    @pool_exhausted[runtime] = begin
      RuntimeAuthProvider.for(runtime).accounts.available.none?
    rescue StandardError => e
      # A runtime that cannot answer is not evidence of an outage. Let the
      # attempt through and let the generator refuse it if it must.
      Rails.logger.warn("[StatusSummaryBackstopJob] Could not read the #{runtime} account pool: #{e.message}")
      false
    end
  end

  # Stamps the session BEFORE the decision to enqueue, so the cost of examining
  # it — including reading its transcript — is paid once per RETRY_INTERVAL
  # whatever the answer turns out to be.
  #
  # `update_columns` rather than `update!`: a bookkeeping stamp is not a change
  # to what the panel says, and SessionStatusSummary broadcasts a panel
  # re-render on every committed update.
  def stamp_examined(session, record)
    (record || SessionStatusSummary.create_or_find_by!(session_id: session.id))
      .update_columns(backstop_attempted_at: Time.current, updated_at: Time.current)
  rescue StandardError => e
    Rails.logger.error("[StatusSummaryBackstopJob] Could not stamp session #{session.id}: #{e.message}")
  end
end
