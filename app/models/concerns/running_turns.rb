# frozen_string_literal: true

# How much of the fleet's turn capacity is in use, and what is stacked up behind
# it.
#
# == `running` is the answer now, not the question
#
# `running` used to be stamped when a turn was HANDED to a session rather than
# when a worker started executing it, so the column held both populations at
# once and this concern existed to tell them apart. Since #1040 the hand-over
# lands in `waiting` and `AgentSessionJob#perform` is the only thing that stamps
# `running`, so a `running` row IS a turn on one of the
# `ConnectionBudget.good_job_queue_threads[:agents]` worker threads.
#
# The split still has to be computed rather than counted, for two reasons that
# outlive the fix. The queue is now inside `waiting`, which also holds every
# dormant session in the deployment, so "how many turns are stacked up behind the
# pool" cannot be a `COUNT(*)` either — it is the `waiting` rows with a READY job
# in the `agents` lane, which is what PendingAgentTurns::Reading#queued means.
# And a `running` row can still briefly hold no worker: a job whose worker was
# SIGKILLed leaves the row `running` until a recovery sweep reaches it.
#
# The counted population is therefore unchanged by #1040, deliberately. It was
# `running` rows whose job had a `performed_at`, and it still is — a `waiting`
# row whose worker is making its clone is reported as awaiting a worker, exactly
# as a first start was before the change. Every ceiling's denominator kept its
# meaning across the refactor; what moved is which STATUS the uncounted turns
# wear.
#
# == The ceilings count worker occupancy, and nothing else
#
# Only `on_a_worker` counts. A turn that is merely queued has taken nothing yet:
# the thing it is waiting for is a worker, and how many turns are stacked up
# behind the pool says how deep the queue is, not how much of the fleet is
# occupied. A ceiling fed the queue depth stops being a limit on concurrent work
# and becomes a limit on demand — which is how the deployment came to read
# "Holding spot sessions: 25 of 10 session slots taken (8 on a worker, 17 waiting
# for one)" with eight agent processes alive and every spot session held.
#
# The queue is still real, so it is reported beside the count rather than
# discarded — see FleetTopUpStatus, SpotGateService#awaiting_clause and the
# /inference cards. It is the same number that made "15 sessions running" read as
# a broken counter in
# [#957](https://github.com/tadasant/zimmer/issues/957), and that the session
# list now shows as `waiting` rather than folding into `running`
# ([#1040](https://github.com/tadasant/zimmer/pull/1040)).
#
# **This bounds every ceiling at .worker_slots**, and deliberately so: the
# counted population is turns a worker is executing, and the pool runs
# `ConnectionBudget.good_job_queue_threads[:agents]` of them. A ceiling
# configured above that can never be reached — .effective_ceiling is the number
# that is actually in force, and both /inference cards and `get_spot_policy` say
# so when the two differ, rather than printing a limit that does nothing. The one
# reading that escapes the bound is the fail-safe below, which reports every
# `running` row as executing and may therefore exceed the pool.
#
# **A ceiling is not the only thing that reasons about this column**, and the two
# that do not are deliberate. SpotGateService prices its projected burn off every
# `running` row, since a session spends from the moment it is handed a turn, and
# waives its pacing curve on that same population; SpotSessionPause's resume
# budget counts the queue too, since a session it resumes joins the queue rather
# than a worker. Both read the split rather than the occupancy, and say why where
# they do it.
#
# == The two populations that are not in flight at all
#
# **A dormant `waiting` row.** Most of `waiting` is this: a spot start-hold, a
# ceiling pause, an auth-outage park, a session asleep on its own wake, a
# clone-only session that has never been given a prompt. None of them has a
# READY job in the `agents` lane, which is exactly how they are excluded — the
# queue bucket is built from PendingAgentTurns, not from the status column. A
# spot-held session's re-check job is `scheduled` rather than `queued` for the
# same reason: its owner is the spot ladder, not the worker pool.
#
# **A `running` row asleep on its own future wake, with no AgentSessionJob at
# all.** Nothing will happen to that session until its wake fires, so it is
# neither on a worker nor waiting for one, and holding a slot in two ceilings
# against it is what pinned both of the deployment's throughput controls in #957.
# It is dropped from `awaiting_a_worker` rather than left in it, so the queue
# figure beside the ceiling stays a count of turns that are genuinely coming.
# Both conditions are load-bearing, and each rules out a way of being wrong:
#
#   * **Asleep**, read exactly the way the start paths read it
#     (.ids_paused_until_scheduled_time). Without it this would be dropping
#     ordinary sessions caught between two jobs.
#   * **Nothing queued for it.** PendingAgentTurns is the existing answer to "is
#     a turn already coming for these sessions", and it reads the job rows rather
#     than `sessions.running_job_id` for the reason documented there —
#     `running_job_id` is written from inside `perform`, so a session whose job
#     is still queued has a blank one.
#
# "And no worker is on it" falls out of the second condition, and it is the half
# that keeps a busy session counted: arming a wake mid-turn is the ordinary
# orchestrator pattern — a router calls `wake_me_up_later` and then keeps working
# for the rest of its turn — so "has a wake armed" alone would stop counting a
# session at the exact moment it is busiest.
#
# A row reaches `running`-while-asleep when its turn ends with something else
# already in flight for it, and that something then finishes without pausing it.
#
# == Fail safe means COUNT it
#
# Both probes reach outside the `sessions` table, and both are rescued toward
# counting. An unreadable `good_jobs` reads as "every turn is on a worker", which
# puts every `running` row into the counted population — the most this concern
# can report, and what these counts were before it existed. Unreadable
# `trigger_conditions` read as "nothing is asleep", which is the counting-toward
# answer for the split: every uncounted row is reported as a turn still coming
# rather than as one nothing will run. A monitoring gap must never make the fleet
# look emptier than it is — the spot gate admits sessions on this reading and
# FleetIdleMonitor spawns them.
#
# Only the FIRST of the two moves what a ceiling counts, since `on_a_worker` is
# the whole of it. The second decides between two uncounted buckets, so it earns
# its place for two other reasons: the split is a figure operators read, and an
# exception escaping here reaches the spot gate — see just below.
#
# The rescues are deliberately `StandardError` rather than
# `ActiveRecord::ActiveRecordError`, because neither probe is only a query:
# .ids_paused_until_scheduled_time filters in Ruby and parses a stored timezone,
# which can raise for a row that reached the table without validation.
# Session.running_claude_code_count rescues the AR family alone, so anything
# wider has to be caught here or it escapes into the spot gate.
module RunningTurns
  extend ActiveSupport::Concern

  # One reading of a scope's `running` rows, split three ways so a caller can
  # both decide on `on_a_worker` and say what the other two hold.
  #
  # `awaiting_a_worker` is deliberately the wider word. It is every row with a
  # turn coming that no agent process is executing yet: turns queued in the
  # `agents` lane (which read `waiting`), turns a worker is holding while it makes
  # the clone and spawns the CLI, and `running` rows between jobs — the handoff
  # window, a first spawn not yet enqueued, and the orphans
  # CleanupOrphanedSessionsJob repairs. Calling all of that "queued" would put a
  # new false claim in place of the one #957 was about.
  #
  # There is deliberately no `total`. Both ceilings compare against
  # `on_a_worker` alone, and a method that added the queue back would be read as
  # the number they act on — see "The ceilings count worker occupancy" above. The
  # other two buckets exist to be REPORTED beside it.
  Reading = Data.define(:on_a_worker, :awaiting_a_worker, :asleep) do
    # Every row this reading looked at that has a turn or is between jobs. It is
    # no longer `COUNT(*) WHERE status = 'running'` — the queue moved into
    # `waiting` in #1040 — so it is kept as the reference point the three buckets
    # add up to, not as a claim about any one status.
    def rows = on_a_worker + awaiting_a_worker + asleep
  end

  EMPTY = Reading.new(on_a_worker: 0, awaiting_a_worker: 0, asleep: 0)

  # How many agent turns this deployment can execute at once: the `agents` lane's
  # own thread count, which is the hard ceiling on `on_a_worker` whatever either
  # policy number is set to. Read here rather than at each call site so the spot
  # gate's hold detail and the /inference cards cannot drift apart.
  def self.worker_slots = ConnectionBudget.good_job_queue_threads[:agents]

  # The ceiling that is actually in force for a configured one. Since the
  # ceilings count `on_a_worker` and the pool runs .worker_slots of those, a
  # policy number above the pool is a number the fleet can never reach: the spot
  # gate would never report `fleet_at_cap` and top-up would always see room.
  #
  # Nothing is clamped on the strength of this — the operator's number is theirs
  # to set, and raising the pool is a deploy away. It exists so /inference and
  # `get_spot_policy` can print the limit that is really binding next to the one
  # that was typed, rather than showing a ceiling that does nothing.
  def self.effective_ceiling(configured) = [ configured, worker_slots ].min

  # Whether a configured ceiling is out of the fleet's reach — the condition
  # those surfaces render the note on.
  def self.ceiling_out_of_reach?(configured) = configured > worker_slots

  class_methods do
    # The in-flight rows in this scope, split by what the fleet is actually doing
    # with them. Only the first bucket is work in progress.
    #
    # Three queries, and both callers memoise the result (SpotGateService#turns,
    # FleetIdleMonitor#check!) because this sits on the spot gate's admission
    # path.
    #
    # @return [RunningTurns::Reading]
    def running_turns
      # Table-qualified: .not_in_frozen_category left-joins `categories`, which
      # also has an `id`, and a bare `pluck(:id)` is ambiguous under it.
      #
      # Both statuses, because the turn a worker is executing and the turn queued
      # behind it now live in different ones (#1040). `waiting` also holds every
      # dormant session in the deployment, which is why only its rows with a READY
      # `agents` job survive the split below.
      rows = pluck_ids_by_status
      return EMPTY if rows.empty?

      ids = rows.map(&:first)
      running_ids = rows.select { |_id, running| running }.map(&:first).to_set
      turns = agent_turns_for(ids, running_ids)

      # BOTH conditions, and the conjunction is the definition. A job with
      # `performed_at` set is on a worker thread; a session that also says
      # `running` has had its agent process spawned by that thread. The rows
      # where the two disagree are the pre-spawn window — a worker holding the
      # job while it makes the clone and starts the CLI — and no agent is
      # executing there yet, which is why they are reported as still awaiting a
      # worker rather than occupying one. That is also exactly the population the
      # `running`-only count excluded before #1040, so the ceilings' denominator
      # is unchanged.
      on_a_worker = turns.on_a_worker & running_ids
      being_set_up = turns.on_a_worker - running_ids

      # A `running` row with no job of its own at all: the handoff window, a first
      # spawn not yet enqueued, and the orphans CleanupOrphanedSessionsJob repairs.
      # A `waiting` row in the same position is simply dormant and is dropped.
      between_jobs = running_ids - turns.on_a_worker - turns.queued
      asleep = ids_asleep_until_a_future_wake(between_jobs.to_a)

      Reading.new(
        on_a_worker: on_a_worker.size,
        awaiting_a_worker: turns.queued.size + being_set_up.size + between_jobs.size - asleep.size,
        asleep: asleep.size
      )
    end

    private

    # The two statuses in one pass, with each row's id and whether it is `running`.
    # One query rather than two: this sits on the spot gate's admission path, and
    # the population it reads is now the whole of `waiting` as well.
    #
    # Table-qualified and compared in Ruby rather than plucking the enum, because
    # `.not_in_frozen_category` left-joins `categories` — which has its own `id` —
    # and a raw `pluck("sessions.status")` skips ActiveRecord's enum casting.
    def pluck_ids_by_status
      running = Session.statuses[:running]
      where(status: [ :running, :waiting ])
        .pluck(Arel.sql("sessions.id"), Arel.sql("sessions.status = #{running.to_i}"))
    end

    # Of these sessions, which have a turn a worker has started, which have one
    # ready in the queue, and which have one parked on a future `scheduled_at`.
    # See PendingAgentTurns.split.
    #
    # Rescued toward "every `running` row is executing", which is the most this
    # concern can report and what these counts were before it existed. It is
    # deliberately `running_ids` rather than every id read: since #1040 the read
    # covers `waiting` too, and seeding the started set with those would report
    # the entire spot queue and every sleeper as "waiting for one of the 8 worker
    # slots" — a monitoring gap must never make the fleet look emptier than it is,
    # and it must not invent a queue either. See "Fail safe means COUNT it" above.
    def agent_turns_for(ids, running_ids)
      PendingAgentTurns.split(ids)
    rescue StandardError => e
      Rails.logger.warn("[RunningTurns] Could not read the agents queue (#{e.class}: #{e.message}) — " \
        "treating every running turn as executing")
      PendingAgentTurns::Reading.new(on_a_worker: running_ids, queued: Set.new, scheduled: Set.new)
    end

    # Of these session ids, the ones paused until a wall-clock time that has not
    # come — the same reading every START path refuses on.
    #
    # .ids_paused_until_scheduled_time deliberately does not rescue, because its
    # other callers are start paths where swallowing the error would strand a
    # session. Here the stakes are reversed: this is a count, and the safe answer
    # is that nobody is asleep, which reports every uncounted row as a turn still
    # coming rather than as one nothing will run.
    def ids_asleep_until_a_future_wake(session_ids)
      return Set.new if session_ids.empty?

      ids_paused_until_scheduled_time(session_ids)
    rescue StandardError => e
      Rails.logger.warn("[RunningTurns] Could not read pending wake-ups (#{e.class}: #{e.message}) — " \
        "counting every running turn")
      Set.new
    end
  end
end
