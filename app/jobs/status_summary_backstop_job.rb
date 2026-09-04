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
#
# **How much it repairs is the lane's answer, not a constant's** (#776). The
# sweep carried the same defect one level down: a hand-picked per-sweep budget,
# written when these enqueues shared the wide `default` lane, survived #763
# moving them onto the two-thread `inference` lane. Ten every five minutes is 120
# arrivals an hour aimed at a lane that drains at most 80 — so during the outage
# the sweep exists to work around, it enqueued faster than the lane could drain,
# and the backlog it built pushed head-of-line ages past the alert thresholds
# three times in five hours on 2026-09-02. The budget is LANE_DEPTH_CEILING less
# what the lane already holds: an arrival-side admission check that paces the
# sweep to the substrate instead of guessing at it. It still repairs during an
# outage — it repairs at exactly the rate the lane can absorb, which is the
# fastest any budget could.
#
# **Who gets that budget is not decided by recency alone** (#881). The budget
# says how much the sweep may repair; the candidate ordering says who gets it.
# Recency alone let a session whose repair can never succeed retake the head
# every RETRY_INTERVAL and hold the whole budget indefinitely, so the sweep now
# reaches never-examined sessions first — in recency order, exactly as before —
# and the rest longest-unexamined first. See #candidates for what that trade
# costs.
class StatusSummaryBackstopJob < ApplicationJob
  queue_as :default
  include SingletonSweep

  # Sessions repaired per sweep ON THE FORK PATH — a COST cap, not a throughput
  # one, and the reason it stands beside LANE_DEPTH_CEILING below rather than
  # being folded into it. Each fork copies a repository and takes an account
  # slot, and the lane's depth says nothing about either, so a healthy lane with
  # room to spare is still not a reason to turn a fleet-wide outage into a
  # fleet-wide re-fork. In steady state it is zero: a session drops out of the
  # candidate set as soon as its summary lands.
  MAX_PER_SWEEP = 5

  # The share of the lane budget the fork path may take WHEN THERE IS ALSO
  # outage work waiting behind it. Both paths draw on one budget, and on a mixed
  # fleet the fork path reaches it first by accident — its sessions simply sort
  # earlier — so without a reservation the expensive repair would crowd out the
  # cheap pool-independent one a quota outage depends on. Half,
  # rounded up, so the fork path keeps the larger share of an odd budget and a
  # headroom of one is still spendable by whichever path reaches it.
  #
  # It engages only when a candidate is actually on an exhausted pool. A fleet
  # with nothing to reserve for pays nothing for this, and the cost cap alone
  # applies.
  FORK_SHARE_UNDER_OUTAGE = 0.5

  # How often this sweep runs. Kept here because LANE_DEPTH_CEILING is derived
  # from it, and pinned against `config/cron_schedule.rb` by this job's test — a
  # cadence changed in one place and not the other would silently resize the
  # admission gate.
  SWEEP_INTERVAL = 5.minutes

  # The most unclaimed SessionStatusSummaryJob rows this sweep will leave behind
  # it on the `inference` lane. It is the sweep's whole enqueue budget, drawn on
  # by BOTH repair paths, and it is measured rather than chosen: the budget for a
  # sweep is LANE_DEPTH_CEILING less what the lane already holds.
  #
  # WHY A MEASUREMENT AND NOT A NUMBER. The number this replaced was sized in
  # throughput terms — "ten every five minutes clears a backlog of a hundred
  # inside an hour" — against the wide `default` lane these enqueues shared when
  # it was written. #763 then moved SessionStatusSummaryJob onto the dedicated
  # two-thread `inference` lane and the arithmetic was never redone: 120 arrivals
  # an hour into a lane whose service rate is at most
  # 2 x 3600/HEADLESS_TIMEOUT = 80/hour is a queue that grows by 40 an hour for as
  # long as there is anything to repair. A hand-picked cap cannot survive the
  # thread count or the timeout changing under it; a headroom read cannot help
  # but track them.
  #
  # THE DERIVATION. One sweep interval of lane time, expressed in jobs: the
  # lane's threads times how many HEADLESS_TIMEOUT-length calls each can finish
  # before the next sweep. At 2 threads, a 5-minute cadence and a 90s timeout
  # that is 6. So the deepest backlog this sweep can be responsible for is one
  # sweep interval of work — head-of-line wait for a row it enqueues stays under
  # LANE_DEPTH_CEILING / (threads / HEADLESS_TIMEOUT) = 270s, an order below the
  # `inference` lane's 60-minute stall threshold in
  # HealthMonitorService::QUEUE_LANE_CRITICAL_THRESHOLDS.
  #
  # THE LANE IS READ OFF THE JOB, not named here. #763 moved
  # SessionStatusSummaryJob between lanes and left this budget describing the one
  # it had left, which is the whole defect; asking the job which lane it is on
  # makes that particular drift impossible rather than merely documented. A
  # `fetch` because a queue ConnectionBudget does not size is a queue GoodJob
  # will not schedule — better a boot failure than a silent one.
  LANE_THREADS = ConnectionBudget.good_job_queue_threads
    .fetch(SessionStatusSummaryJob.queue_name.to_sym)

  # THE FLOOR IS NOT DECORATION. A deployment that sets GOOD_JOB_INFERENCE_THREADS
  # low enough, or a timeout raised past the cadence, would otherwise derive zero
  # and turn the sweep into the no-op its whole header argues against. One repair
  # a sweep is slow; none is a different job.
  LANE_DEPTH_CEILING = [
    LANE_THREADS * SWEEP_INTERVAL.to_i / SessionStatusSummaryGenerator::HEADLESS_TIMEOUT,
    1
  ].max

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
    gated = false

    scanned = candidates.to_a

    # Read ONCE, before the walk. The sweep's own enqueues land in the same table
    # this counts, so re-reading it per session would count them twice and shrink
    # the budget the sweep is in the middle of spending.
    queued = PendingSessionJob.queued_count(SessionStatusSummaryJob)
    headroom = [ LANE_DEPTH_CEILING - queued, 0 ].max
    fork_budget = fork_budget_for(scanned, headroom)

    scanned.each do |session|
      # The lane's admission gate, and the only budget whose exhaustion means
      # there is nothing left this sweep can do: both repair paths enqueue a
      # SessionStatusSummaryJob onto the lane, so one already holding
      # LANE_DEPTH_CEILING unclaimed rows has no room for either of them.
      # Recorded rather than silently broken out of, because a truncated sweep
      # otherwise reads as "nothing left to repair".
      if forked + headless >= headroom
        gated = true
        break
      end

      next if session.blocked_on_elicitation?

      record = session.status_summary
      next unless due?(record)

      # Which path would repair this session decides which cost cap it answers
      # to. #pool_exhausted? is memoized per runtime: one query per sweep, not
      # one per session.
      outage = pool_exhausted?(session.agent_runtime)

      # The fork path's own budget: its cost cap, reduced to a share of the lane
      # when outage work is also waiting. A `next` rather than a `break`, so a
      # mixed fleet — one runtime's pool exhausted, another's healthy — does not
      # have the walk ended over the headless repairs behind it, which cost
      # neither a clone copy nor an account slot. Asked BEFORE the session is
      # stamped, so a session skipped for a spent budget does not also spend its
      # retry interval on a budget it never got past.
      next if !outage && forked >= fork_budget

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

    if gated
      # The MEASURED depth, not the ceiling: "held 60 against a ceiling of 6" and
      # "held 6" are the same headroom and very different incidents, and this is
      # the only signal an operator gets for either.
      Rails.logger.warn(
        "[StatusSummaryBackstopJob] lane admission gate reached: #{SessionStatusSummaryJob.queue_name} " \
        "holds #{queued} unclaimed SessionStatusSummaryJob rows against " \
        "LANE_DEPTH_CEILING=#{LANE_DEPTH_CEILING} (headroom #{headroom}); " \
        "any candidates left wait for a later sweep"
      )
    end

    return if forked.zero? && headless.zero?

    Rails.logger.info(
      "[StatusSummaryBackstopJob] enqueued_forks=#{forked} enqueued_headless=#{headless} " \
      "lane_queued=#{queued} lane_headroom=#{headroom} fork_budget=#{fork_budget}"
    )
  end

  private

  # What the fork path may spend of the shared lane budget.
  #
  # Its cost cap, except when a candidate is on an exhausted pool — then the
  # cheap pool-independent path needs a share of the same budget, and the fork
  # path reaching it first is an artefact of the candidate ordering rather than a
  # priority anyone chose. #pool_exhausted? is memoized per runtime, so this
  # costs one query per distinct runtime whether it is asked here or in the walk.
  def fork_budget_for(sessions, headroom)
    return MAX_PER_SWEEP unless sessions.any? { |session| pool_exhausted?(session.agent_runtime) }

    [ MAX_PER_SWEEP, (headroom * FORK_SHARE_UNDER_OUTAGE).ceil ].min
  end

  # Sessions at rest, in the order this sweep's budget should be spent: the ones
  # it has never looked at first — most recently active among them — and then the
  # ones it looked at longest ago.
  #
  # **WHY THERE IS A FAIRNESS TERM AT ALL** (#881). The ordering was
  # `updated_at DESC` alone: the order the user's action queue is read in, so the
  # cap spends itself on the sessions most likely to be opened next. That is a
  # priority with no fairness term, and a session whose repair can never
  # succeed — the reclaimed-clone case RETRY_INTERVAL already anticipates — is
  # stale forever. It comes due again every RETRY_INTERVAL and, if it is among the
  # most recently active, retakes the head. LANE_DEPTH_CEILING such sessions
  # therefore took the entire budget on every sweep, indefinitely, while the sweep
  # logged `enqueued_headless=6` as though it were making progress. Nothing
  # further down the list was ever reached.
  #
  # **WHAT IT COSTS, AND WHAT IT DOES NOT.** Sorting on `backstop_attempted_at`
  # means a session the sweep has already spent a slot on cannot outrank one it
  # has not. It does *not* flatten the recency priority, because a session that
  # has never been examined has no stamp: the whole first group ties on NULL, and
  # `updated_at DESC` still decides between them. A session's FIRST look is
  # ordered exactly as it was before. Only re-examinations are demoted — behind
  # every first look, and among themselves oldest-stamp first, which is a rotation
  # no member can hold the head of.
  #
  # The price is paid by a retry that would have succeeded: a session whose
  # generation was lost to a deploy now waits behind the sessions the sweep has
  # not looked at yet, rather than ahead of them by virtue of being recent. That
  # is the right way round. An unexamined session may well be repaired by its
  # first slot, whereas a second attempt is by construction evidence that one slot
  # was not enough.
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
  #
  # Neither ordering column is indexed, and neither was: the sort runs over what
  # the due-ness `WHERE` left behind, which in steady state is nothing and under
  # SCAN_LIMIT is at most a few hundred rows.
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
      .order("session_status_summaries.backstop_attempted_at ASC NULLS FIRST", "sessions.updated_at DESC")
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
