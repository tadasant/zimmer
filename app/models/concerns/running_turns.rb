# frozen_string_literal: true

# What `sessions.status = running` actually holds, and how much of it is work
# the fleet can be doing.
#
# == Why one row in `running` is not one turn being executed
#
# `running` is stamped when a turn is HANDED to a session, not when a worker
# starts executing it. Every delivery path does the same two things in order —
# flip the session to `running`, then enqueue an AgentSessionJob: a fired wake
# trigger, a web or API follow-up, a poller's comment, the enqueued-message
# handoff at the end of a turn (AgentSessionJob#handed_off_to_enqueued_message?),
# and every recovery sweep. The `agents` GoodJob queue sits between the two, and
# it is only GOOD_JOB_AGENTS_THREADS deep (ConnectionBudget). On a busy
# deployment that gap is minutes, so `running` routinely holds a substantial
# population of turns that are queued for a worker rather than being run by one.
#
# Both populations are work in flight and both count against a concurrency
# ceiling. A queued turn is committed demand: it will take a worker slot as soon
# as one frees, so a gate that ignored it would admit more work into the same
# queue. The split is reported rather than discarded — see FleetTopUpStatus and
# the /inference cards, where "15 sessions running" was read as a broken counter
# ([#957](https://github.com/tadasant/zimmer/issues/957)) precisely because the
# page had no way to say "8 on a worker, 7 waiting for one".
#
# == The one population that does not count
#
# A row that is BOTH asleep on its own future wake AND has no worker on it.
#
# Every start path already refuses to start such a session before its wake:
# AgentSessionJob#paused_until_scheduled_time? stands down for it and
# deliberately does NOT re-enqueue, because the armed wake is the next event in
# that session's life. So the fleet cannot spend a worker on it however long it
# sits there, and counting it holds a slot in two ceilings against work that
# provably cannot run. It reaches `running` rather than `waiting` when its turn
# ends while something else is already in flight for it — a queued message the
# handoff path picks up, or a recovery job CleanupOrphanedSessionsJob enqueued.
#
# **Both halves are load-bearing.** Arming a wake mid-turn is the ordinary
# orchestrator pattern — a router calls `wake_me_up_later` and then keeps working
# for the rest of its turn — so "has a future wake" alone would stop counting a
# session at the exact moment it is busiest. Requiring "and no worker is on it"
# keeps every working session counted and drops only the ones that have stopped.
#
# == Fail safe means COUNT it
#
# Both probes reach outside the `sessions` table, and both are rescued toward
# counting. An unreadable `good_jobs` reads as "every turn is on a worker", and
# an unreadable `trigger_conditions` reads as "nothing is asleep": either way the
# total is every `running` row, which is what these counts were before this
# concern existed. A monitoring gap must never make the fleet look emptier than
# it is — the spot gate admits sessions on this reading and FleetIdleMonitor
# spawns them.
module RunningTurns
  extend ActiveSupport::Concern

  # One reading of a scope's `running` rows, split three ways so a caller can
  # both decide on the total and say where it came from.
  #
  # `total` deliberately omits `asleep`: it is the number every ceiling compares
  # against, and the sleepers are the population this concern exists to drop.
  Reading = Data.define(:on_a_worker, :queued_for_a_worker, :asleep) do
    def total = on_a_worker + queued_for_a_worker

    # Every `running` row, sleepers included — what the ceilings counted before
    # and what /inference needs to explain the difference.
    def rows = total + asleep
  end

  EMPTY = Reading.new(on_a_worker: 0, queued_for_a_worker: 0, asleep: 0)

  # How many agent turns this deployment can execute at once: the `agents` lane's
  # own thread count, which is the real ceiling on `on_a_worker` whatever either
  # policy number is set to. Read here rather than at each call site so the spot
  # gate's hold detail and the /inference cards cannot drift apart.
  def self.worker_slots = ConnectionBudget.good_job_queue_threads[:agents]

  class_methods do
    # The `running` rows in this scope the fleet can be working on, split.
    #
    # @return [RunningTurns::Reading]
    def running_turns
      # Table-qualified: .not_in_frozen_category left-joins `categories`, which
      # also has an `id`, and a bare `pluck(:id)` is ambiguous under it.
      rows = where(status: :running).pluck("sessions.id", "sessions.running_job_id")
      return EMPTY if rows.empty?

      started = job_ids_on_a_worker(rows.map(&:last))
      working, idle = rows.partition { |_id, job_id| started.include?(job_id) }
      asleep = ids_asleep_until_a_future_wake(idle.map(&:first))

      Reading.new(
        on_a_worker: working.size,
        queued_for_a_worker: idle.size - asleep.size,
        asleep: asleep.size
      )
    end

    private

    # Of these `running_job_id`s, the ones a worker has actually started and not
    # finished — GoodJob's own record of "something picked this up".
    #
    # A blank id is not one of them. It is the handoff window
    # (EnqueuedMessageProcessorService clears `running_job_id` so the incoming
    # job is not mistaken for a superseded one) and the moments either side of a
    # first spawn. Those sessions are between jobs, which is exactly the queued
    # population.
    #
    # `performed_at` present with `finished_at` absent is deliberately looser
    # than JobLiveness's `:running` — a job whose worker died still reads as
    # started here. That is the counting direction to be wrong in, and
    # CleanupOrphanedSessionsJob is what repairs the row.
    #
    # AgentSessionJob::LIVE_EXECUTIONS is unioned in for the same reason that job
    # consults it first: a phantom re-pick makes the ROW lie, stamping
    # `finished_at` while the original execution runs on. The set is per-process,
    # so it only ever adds — the web process rendering /inference sees none of the
    # worker's executions — which is the direction that cannot undercount.
    def job_ids_on_a_worker(active_job_ids)
      ids = active_job_ids.compact_blank
      return Set.new if ids.empty?

      GoodJob::Job
        .where(active_job_id: ids)
        .where.not(performed_at: nil)
        .where(finished_at: nil)
        .pluck(:active_job_id)
        .to_set
        .merge(ids.select { |id| AgentSessionJob.executing?(id) })
    rescue StandardError => e
      # Deliberately broad and deliberately toward counting: GoodJob's tables are
      # not Zimmer's, and anything from a missing table to a connection timeout
      # must leave the totals where they were rather than emptying the fleet.
      Rails.logger.warn("[RunningTurns] Could not read the agents queue (#{e.class}: #{e.message}) — " \
        "treating every running turn as executing")
      ids.to_set
    end

    # Of these session ids, the ones paused until a wall-clock time that has not
    # come — the same reading every START path refuses on.
    #
    # .ids_paused_until_scheduled_time deliberately does not rescue, because its
    # other callers are start paths where swallowing the error would strand a
    # session. Here the stakes are reversed: this is a count, and the safe answer
    # is that nobody is asleep, which leaves the total at every `running` row.
    def ids_asleep_until_a_future_wake(session_ids)
      return Set.new if session_ids.empty?

      ids_paused_until_scheduled_time(session_ids)
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[RunningTurns] Could not read pending wake-ups (#{e.message}) — " \
        "counting every running turn")
      Set.new
    end
  end
end
