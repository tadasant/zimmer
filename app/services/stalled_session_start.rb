# frozen_string_literal: true

# Restarts a session whose very first turn was enqueued and then lost.
#
# == The hole this closes
#
# A session is created in `waiting` and an AgentSessionJob is enqueued for it.
# That one job is the entire thread back to life for a session that has never
# run — and unlike a spot hold (`SpotSessionHold`), a ceiling pause
# (`SpotSessionPause`), an auth-outage park (`AuthOutageParkService`) or a
# recovery pause (`metadata["paused_by"]`), a queued-but-never-started session
# carries **no marker at all**. It is a plain `waiting` row, indistinguishable
# from a session created one second ago.
#
# So when that job goes missing, nothing looks for it. `CleanupOrphanedSessionsJob`
# and `DeploymentRecoveryJob` scan `running`, plus `paused_by = 'recovery'`, plus
# `failed` with an InterruptError. `SpotHoldSweepJob` reads the hold population,
# `SpotCeilingSweepJob` the pause population, `QuotaResetCheckerJob` the parked
# one. A refresh will not rescue it either: `Session#continue_nudge_on_refresh?`
# returns false for a session with no `session_id`, deliberately, because "the
# spawn pipeline still owns it". Nothing owned it.
#
# Session 10426 sat there for three days. It was `priority`, so the spot gate was
# never involved: a merge gate spawned by a `ready to merge` label at 15:53 on
# 2026-08-29, with two log lines from the title and category jobs and nothing
# else, while the PR it was created to gate was merged by a human seven minutes
# later. Nothing detected it, and nothing would have.
#
# The job is lost in more than one way, which is why the repair is keyed on the
# state rather than on a cause:
#
#   * The requeue that `AgentSessionJob#requeue_interrupted_start` performs is
#     itself one job. Its whole rescue is wrapped in a bare `rescue => e` that
#     only writes to `Rails.logger` — a DB connection lost in a shutdown window
#     takes the replacement with it, silently.
#   * `retry_on` budgets on `AgentSessionJob` and `ApplicationJob` re-raise once
#     spent, and GoodJob then finishes the row. The session's status is untouched
#     because `perform` never got far enough to touch it.
#   * The attachment-copy failure paths in `SessionsController#quick_prompt` and
#     `#chat_bubble` create the session with `skip_enqueue: true`, then raise
#     before reaching the enqueue. The human gets a flash message; the session row
#     stays in `waiting` forever.
#
# == What makes a session stalled
#
# Four conditions, and each one is doing work:
#
#   1. `waiting` with no `session_id`. The same predicate every other recovery
#      path uses for "has never run" (`AgentSessionJob#handle_interrupt_error`
#      case 1). A session that HAS run and is stranded in `waiting` reaches
#      recovery through `paused_by = 'recovery'` instead, and re-running its
#      start job would re-clone underneath a conversation that already exists.
#   2. Quiet for GRACE, by `created_at` AND `updated_at`. Every legitimate reason
#      for a `waiting` row to have no job yet — the milliseconds between
#      `Session.create!` and `perform_later`, the moments before a worker picks
#      the job up — is measured in seconds. Reading `updated_at` too is what
#      gives the repair its cooldown: recording an attempt goes through
#      `merge_metadata!`, which stamps `updated_at`, so a restarted session is
#      out of this population for another GRACE whether or not GoodJob can be
#      read. That is the second, independent guard against a stacked turn.
#   3. No unfinished AgentSessionJob (`PendingAgentTurns`). This is the guard
#      that keeps a congested `agents` queue from being mistaken for a lost job,
#      and it is what makes a duplicated turn impossible in the ordinary case:
#      a job queued, delayed, or mid-execution all read as pending.
#   4. Not dormant on purpose. A hold, a ceiling pause, an auth park, a recovery
#      pause and an armed wake each own their own way back, and starting a
#      session underneath one of them undoes the decision that stopped it.
#
# == What it does about it
#
# `Sessions::StartNow` — the one place that already knows which door a dormant
# session comes back through, and which re-reads the queue before it enqueues
# anything. For this population it resolves to "nothing is queued and nothing
# ever started", which is the single case where enqueuing is the right answer
# rather than a duplicate.
#
# Bounded at MAX_RESTARTS. A session whose start job keeps disappearing is not a
# session to re-enqueue forever: past the budget it is FAILED, with a
# `failure_reason` that says so, because a `failed` row is on the dashboard and a
# `waiting` one is not. That is the same trade `requeue_interrupted_start` makes.
class StalledSessionStart
  # How long a `waiting` session with no job may be given the benefit of the
  # doubt. Long enough to cover a worker that is down through a deploy (its job
  # is still in the queue, so condition 3 covers that anyway) and short enough
  # that the answer to "how long can a session sit unstarted" is minutes rather
  # than days.
  GRACE = 10.minutes

  # How many times one session may have its first turn re-enqueued before Zimmer
  # stops trying and fails it. Each attempt is at least GRACE apart, so this is
  # about half an hour of trying.
  MAX_RESTARTS = 3

  # Bounds on one pass. The read is bounded separately from the batch so that a
  # deployment which has somehow stalled a hundred sessions does not load them
  # all to act on ten.
  #
  # Sessions that are skipped rather than restarted — one with a job still
  # queued, one asleep on a wake — are dropped BEFORE the batch is taken, so they
  # cannot consume the restart budget. They can still consume the LOAD window,
  # since the query orders oldest-first and nothing they do advances their
  # timestamps; 5x the batch is the headroom against that, the same ratio
  # SpotSessionHold uses for the same reason.
  MAX_RESTARTS_PER_SWEEP = 10
  MAX_LOADED_PER_SWEEP = MAX_RESTARTS_PER_SWEEP * 5

  # How many times this sweep has restarted this session.
  RESTART_COUNT = "stalled_start_restarts"

  # Markers that mean "asleep on purpose", each owned by a sweep of its own.
  # Filtered in SQL because they are cheap there and because the population this
  # query runs over is mostly the spot queue, which carries `spot_hold_reason` on
  # every row.
  DORMANT_MARKERS = %w[
    spot_hold_reason
    spot_pause_reason
    auth_outage_reason
    paused_by
  ].freeze

  Sweep = Data.define(:restarted, :stalled, :skipped, :dormant, :failed)

  class << self
    # Sessions that have been in `waiting` without ever starting for longer than
    # `grace`, oldest first. Cheap markers only — the questions that cost a query
    # per session (an armed wake, a pending job) are asked in #sweep! against the
    # bounded set this returns.
    #
    # @return [ActiveRecord::Relation<Session>]
    def stalled_sessions(now: Time.current, grace: GRACE)
      cutoff = now - grace

      relation = Session
        .not_in_frozen_category
        .where(status: :waiting)
        # A blank runtime session id is what "has never run" means everywhere
        # else in recovery, and it is also what keeps this sweep off a
        # status-summary fork: ForkSessionService issues one at creation
        # (`session_id: new_session_id`, `status: :needs_input`), so a fork that
        # never got its prompt — tadasant/zimmer#730 — is out of this population
        # rather than being started as a full agent session (#716).
        .where("sessions.session_id IS NULL OR sessions.session_id = ''")
        .where(created_at: ...cutoff)
        .where(updated_at: ...cutoff)
        # A session with no prompt was never given anything to do. The only way
        # to reach `waiting` without one is a clone-only setup, whose repair is
        # a clone rather than a turn — see the limitations page.
        .where.not(prompt: [ nil, "" ])

      DORMANT_MARKERS.reduce(relation) do |scope, marker|
        scope.where("sessions.metadata->>? IS NULL", marker)
      end.order(:created_at)
    end

    # One pass.
    #
    # Never raises: it runs on a cron beside everything else and the condition is
    # re-read from scratch five minutes later, so a failed pass costs a pass.
    #
    # @return [Sweep]
    def sweep!(logger: nil)
      logger ||= StructuredLogger.new({ service: "StalledSessionStart" })

      # Counted before the read is bounded, so the number in the log is the size
      # of the problem rather than the size of this batch. A sweep that says
      # "3 stalled" while 200 sessions are stranded is the kind of figure that
      # misleads precisely when someone is reading it during an incident.
      stalled = stalled_sessions.count
      return Sweep.new(restarted: 0, stalled: 0, skipped: 0, dormant: 0, failed: 0) if stalled.zero?

      loaded = stalled_sessions.limit(MAX_LOADED_PER_SWEEP).to_a
      queued = PendingAgentTurns.for(loaded.map(&:id))
      candidates, skipped = loaded.partition { |session| queued.exclude?(session.id) }
      candidates, dormant = candidates.partition { |session| !asleep_on_a_wake?(session) }

      batch = candidates.first(MAX_RESTARTS_PER_SWEEP)

      logger.info("Sessions have been waiting to start with no job behind them",
        stalled: stalled, with_a_job_still_queued: skipped.size,
        asleep_on_a_wake: dormant.size, in_this_batch: batch.size)

      restarted = 0
      failed = 0
      batch.each do |session|
        case restart!(session, logger)
        when :restarted then restarted += 1
        when :failed then failed += 1
        end
      end

      Sweep.new(restarted: restarted, stalled: stalled, skipped: skipped.size,
                dormant: dormant.size, failed: failed)
    rescue StandardError => e
      logger.warn("Stalled-start sweep failed", error: "#{e.class}: #{e.message}")
      Sweep.new(restarted: 0, stalled: 0, skipped: 0, dormant: 0, failed: 0)
    end

    private

    # An armed one-time wake is the broader question `awaiting_scheduled_wake?`
    # answers, and the broad one is right here: this sweep is not a start path
    # that has to let a due `ao_event` watcher through, it is a repair that
    # should keep its hands off anything with a next event of its own. It fails
    # safe to "asleep" when the trigger table cannot be read, which costs a pass.
    def asleep_on_a_wake?(session)
      session.awaiting_scheduled_wake?
    end

    # Put one stalled session back on its way, or give up on it.
    #
    # @return [Symbol] :restarted, :failed, or :skipped
    def restart!(session, logger)
      session.reload
      count = (session.metadata || {})[RESTART_COUNT].to_i
      return give_up!(session, count, logger) if count >= MAX_RESTARTS

      result = Sessions::StartNow.call(session, actor: "Zimmer's stalled-start sweep")
      unless result.started?
        # Not an error. Something changed between the read and here — the session
        # started, was archived, or acquired a wake — and StartNow refusing is
        # the guard doing its job. The next pass re-reads everything.
        logger.info("Left a stalled session alone",
          session_id: session.id, outcome: result.outcome, reason: result.message)
        return :skipped
      end

      # Written AFTER the enqueue: the budget exists to stop Zimmer re-enqueuing
      # forever, so it must only count turns that were actually enqueued.
      session.merge_metadata!(RESTART_COUNT => count + 1)

      session.logs.create!(
        level: "warning",
        content: "This session was created #{age_phrase(session)} and never started: the job that " \
                 "would have run its first turn is gone, and nothing was left to start it. Zimmer's " \
                 "stalled-start sweep enqueued it again (attempt #{count + 1} of #{MAX_RESTARTS})."
      )
      logger.info("Restarted a session that never started",
        session_id: session.id, attempt: count + 1, created_at: session.created_at.utc.iso8601)
      :restarted
    rescue StandardError => e
      logger.warn("Could not restart a stalled session",
        session_id: session.id, error: "#{e.class}: #{e.message}")
      :skipped
    end

    # Past the budget, stop re-enqueuing and make the session visible instead.
    #
    # A `waiting` row is on nobody's list; a `failed` one is on the dashboard,
    # carries its reason, and can be restarted by a human who wants to try again.
    def give_up!(session, count, logger)
      session.logs.create!(
        level: "error",
        content: "This session's first turn has been enqueued #{count} times and has never run. " \
                 "Zimmer is not re-queuing it again — failing it so it stops sitting in `waiting` " \
                 "where nothing is watching."
      )
      session.merge_metadata!(
        "failure_reason" => "Session never started: Zimmer re-queued its first turn #{count} times " \
                            "and the job never ran"
      )
      session.reload
      session.fail! if session.may_fail?

      logger.warn("Gave up restarting a session that never started",
        session_id: session.id, attempts: count)
      :failed
    rescue StandardError => e
      logger.warn("Could not fail a session that never started",
        session_id: session.id, error: "#{e.class}: #{e.message}")
      :skipped
    end

    def age_phrase(session)
      "#{ActionController::Base.helpers.time_ago_in_words(session.created_at)} ago"
    rescue StandardError
      "at #{session.created_at.utc.iso8601}"
    end
  end
end
