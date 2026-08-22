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
# **An auth outage changes HOW it repairs, not whether it does.** A quota-exhausted
# pool is the single biggest producer of the failures this sweep repairs, and
# re-forking into an empty pool produces one more parked fork holding one more
# clone copy — so during an outage the sweep does not fork. It asks for the
# pool-independent one-shot generation instead (SessionStatusSummaryGenerator's
# headless mode), which needs no account, no clone and no agent turn.
#
# This is the fix for the defect the first version of this sweep still had: it
# stood down entirely during an outage, which gated the retry on the very
# resource whose absence caused the failure being retried. On a deployment under
# sustained quota pressure that meant a session at rest never got its blurb at
# all — the panel said "the summary fork was parked, it will be retried" for
# hours, and the retry that would have fixed it was the thing standing down.
class StatusSummaryBackstopJob < ApplicationJob
  queue_as :default
  include SingletonSweep

  # Sessions repaired per sweep. Each repair costs a fork of a repository and an
  # agent turn, so the cap is what keeps a bad day — a fleet-wide outage that
  # failed every generation at once — from becoming a fleet-wide re-fork. In
  # steady state it is zero: a session drops out of the candidate set as soon as
  # its summary lands.
  MAX_PER_SWEEP = 5

  # Repairs per sweep on the headless path, which is what an outage uses. Higher
  # than MAX_PER_SWEEP because the costs are not comparable: a fork copies a
  # repository and takes an account slot, while this is one small-model
  # completion. It still has a cap, because an outage makes EVERY session at rest
  # a candidate at once and a sweep must not turn that into an unbounded burst of
  # subprocesses. Ten every five minutes clears a backlog of a hundred inside an
  # hour.
  MAX_HEADLESS_PER_SWEEP = 10

  # How long to leave a session alone after examining it. Longer than
  # SessionStatusSummary::PENDING_TIMEOUT so an in-flight generation is never
  # raced by the next sweep, and long enough that a session which can never be
  # summarized — one whose clone has been reclaimed — costs one refused enqueue
  # per half hour rather than one per sweep.
  RETRY_INTERVAL = 30.minutes

  # Backstop on the candidate scan itself. #candidates already filters to rows
  # that are due, so in steady state this is nowhere near reached — it is here so
  # that a pathological fleet (thousands of sessions at rest, all due at once
  # after a long outage) cannot turn one sweep into an unbounded scan. A sweep
  # that hits it says so, because a silently truncated sweep reads as "nothing
  # left to repair".
  SCAN_LIMIT = 200

  def perform
    forked = 0
    headless = 0

    scanned = candidates.to_a

    scanned.each do |session|
      # Only when BOTH budgets are spent is there nothing left this sweep can
      # do. Breaking as soon as EITHER is spent would starve the other path on a
      # mixed fleet — one runtime's pool exhausted and another's healthy — by
      # ending the walk on the first session of whichever kind filled up first.
      break if forked >= MAX_PER_SWEEP && headless >= MAX_HEADLESS_PER_SWEEP
      next if session.blocked_on_elicitation?

      record = session.status_summary
      next unless due?(record)

      # Which path would repair this session decides which budget it draws on.
      # #pool_exhausted? is memoized per runtime: one query per sweep, not one
      # per session.
      outage = pool_exhausted?(session.agent_runtime)

      # Asked BEFORE the session is stamped, so a session skipped for a spent
      # budget does not also spend its retry interval on a cap it never got
      # past — the next sweep picks it up.
      next if outage ? headless >= MAX_HEADLESS_PER_SWEEP : forked >= MAX_PER_SWEEP

      stamp_examined(session, record)
      next unless needs_repair?(session, record)

      SessionStatusSummaryJob.perform_later(session.id, headless: outage)
      outage ? headless += 1 : forked += 1
    end

    if scanned.length >= SCAN_LIMIT
      Rails.logger.warn(
        "[StatusSummaryBackstopJob] candidate scan hit SCAN_LIMIT=#{SCAN_LIMIT}; " \
        "sessions beyond it wait for a later sweep"
      )
    end

    return if forked.zero? && headless.zero?

    Rails.logger.info(
      "[StatusSummaryBackstopJob] enqueued_forks=#{forked} enqueued_headless=#{headless}"
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
  # Two things keep this cheap enough to run every five minutes.
  #
  # **Due-ness is a WHERE, not a filter in Ruby.** A session examined inside
  # RETRY_INTERVAL is excluded by the database, so the steady state — every
  # session at rest already carrying a fresh stamp — returns no rows at all
  # rather than the whole action queue. #due? still has the final say (it also
  # refuses a generation that is in flight, which is a two-column predicate not
  # worth expressing here), but it is now deciding over a handful of rows.
  #
  # **`transcript` is left out of the SELECT**, because it is by far the largest
  # column in the schema — megabytes on a long session. Only #needs_repair? needs
  # it, and it fetches it one row at a time. The columns are qualified because the
  # join puts a second `id`, `created_at` and `updated_at` in scope.
  #
  # `preload` rather than a second query per row: the record each candidate needs
  # is fetched once for the whole batch.
  def candidates
    Session
      .excluding_status_summary_forks
      .where(status: [ :needs_input, :failed ])
      .left_joins(:status_summary)
      .where(
        "session_status_summaries.id IS NULL " \
        "OR session_status_summaries.backstop_attempted_at IS NULL " \
        "OR session_status_summaries.backstop_attempted_at < ?",
        RETRY_INTERVAL.ago
      )
      .preload(:status_summary)
      .select((Session.column_names - [ "transcript" ]).map { |column| "sessions.#{column}" })
      .order("sessions.updated_at DESC")
      .limit(SCAN_LIMIT)
  end

  # Whether this session is due to be looked at again. A record that does not
  # exist yet has never been looked at; a `pending` one has a generation in
  # flight and is not this sweep's business.
  def due?(record)
    return true if record.nil?
    return false if record.pending?

    record.backstop_attempted_at.nil? || record.backstop_attempted_at < RETRY_INTERVAL.ago
  end

  # Whether the last generation failed to leave a CURRENT summary behind.
  #
  # Staleness is the whole test, and `failed` is deliberately not a second one.
  # `SessionStatusSummary#stale?` is already true for a blank summary, so every
  # failure that matters — a fork that answered nothing, a claim abandoned before
  # it wrote — is covered. A `failed` record whose summary is nonetheless CURRENT
  # is the case that must not be repaired: it is what a forced Regenerate that
  # then failed leaves behind, the generator would answer an unforced retry with
  # "Summary is current" without clearing the state, and the session would be
  # re-enqueued every RETRY_INTERVAL forever, spending a slot the sessions that
  # can be repaired need.
  #
  # A session with no transcript is refused first, for the same reason
  # SessionStateMachine#enqueue_status_summary_refresh refuses it: there is
  # nothing to summarize, so the generator would decline and the sweep would have
  # spent a slot learning that.
  def needs_repair?(session, record)
    line_count = Session.transcript_line_count(transcript_of(session))
    return false if line_count.zero?
    return true if record.nil?

    record.stale?(line_count)
  end

  # The one column #candidates deliberately did not select, fetched for the
  # single row that needs it.
  def transcript_of(session) = Session.where(id: session.id).pick(:transcript)

  # Whether the runtime's login pool has nothing left to run a fork on — which
  # is what picks the repair mode for every session on that runtime this sweep.
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
  # `update_columns` rather than `update!`: a bookkeeping stamp is not a change to
  # what the panel says, and SessionStatusSummary broadcasts a panel re-render on
  # every committed update. Creating the row when there is none does broadcast —
  # `after_commit … on: [:create, :update]` — but that happens once per session
  # ever, and the panel it renders is the one the reader is about to want.
  def stamp_examined(session, record)
    (record || SessionStatusSummary.create_or_find_by!(session_id: session.id))
      .update_columns(backstop_attempted_at: Time.current, updated_at: Time.current)
  rescue StandardError => e
    Rails.logger.error("[StatusSummaryBackstopJob] Could not stamp session #{session.id}: #{e.message}")
  end
end
