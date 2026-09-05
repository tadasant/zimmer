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
# it is only `ConnectionBudget.good_job_queue_threads[:agents]` deep. On a busy
# deployment that gap runs to minutes, so `running` routinely holds a
# substantial population of turns that are queued for a worker rather than being
# run by one.
#
# Both populations count. A queued turn is committed demand: it takes a worker
# slot as soon as one frees, so a ceiling that ignored it would admit more work
# into the same queue. The split is reported rather than discarded — see
# FleetTopUpStatus and the /inference cards, where "15 sessions running" was read
# as a broken counter ([#957](https://github.com/tadasant/zimmer/issues/957))
# precisely because the page had no way to say "8 on a worker, 7 waiting for
# one".
#
# == The one population that does not count
#
# A row that is asleep on its own future wake AND has **no AgentSessionJob at
# all** — none running, none queued. Nothing will happen to that session until
# its wake fires, so it can consume no capacity in the meantime, and holding a
# slot in two ceilings against it is what pinned both of the deployment's
# throughput controls in #957.
#
# Both conditions are load-bearing, and each rules out a way of being wrong:
#
#   * **Asleep**, read exactly the way the start paths read it
#     (.ids_paused_until_scheduled_time). Without it this would be dropping
#     ordinary sessions caught between two jobs.
#   * **Nothing queued for it.** This is the one that is easy to get wrong, and
#     it is NOT interchangeable with "a start path would refuse it".
#     AgentSessionJob's pause guard is conjoined with `session.waiting?` and
#     `follow_up_prompt.blank?`, so it does not fire for a `running` row at all:
#     a queued job would run the session and take a worker while this concern
#     had stopped counting it. PendingAgentTurns is the existing answer to "is a
#     turn already coming for these sessions", and it reads the job rows rather
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
# counting. An unreadable `good_jobs` reads as "every turn is on a worker", and
# unreadable `trigger_conditions` read as "nothing is asleep": either way the
# total is every `running` row, which is what these counts were before this
# concern existed. A monitoring gap must never make the fleet look emptier than
# it is — the spot gate admits sessions on this reading and FleetIdleMonitor
# spawns them.
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
  # both decide on the total and say where it came from.
  #
  # `awaiting_a_worker` is deliberately the wider word. It is every counted row
  # no worker has started: turns queued in the `agents` lane, and rows between
  # jobs — the handoff window, a first spawn not yet enqueued, and the orphans
  # CleanupOrphanedSessionsJob repairs. Calling all of that "queued" would put a
  # new false claim in place of the one #957 was about.
  #
  # `total` omits `asleep`: it is the number every ceiling compares against, and
  # the sleepers are the population this concern exists to drop.
  Reading = Data.define(:on_a_worker, :awaiting_a_worker, :asleep) do
    def total = on_a_worker + awaiting_a_worker

    # Every `running` row, sleepers included — what the ceilings counted before,
    # and what /inference needs in order to explain the difference.
    def rows = total + asleep
  end

  EMPTY = Reading.new(on_a_worker: 0, awaiting_a_worker: 0, asleep: 0)

  # How many agent turns this deployment can execute at once: the `agents` lane's
  # own thread count, which is the real ceiling on `on_a_worker` whatever either
  # policy number is set to. Read here rather than at each call site so the spot
  # gate's hold detail and the /inference cards cannot drift apart.
  def self.worker_slots = ConnectionBudget.good_job_queue_threads[:agents]

  class_methods do
    # The `running` rows in this scope the fleet can be working on, split.
    #
    # Two queries beyond the row read, and both callers memoise the result
    # (SpotGateService#turns, FleetIdleMonitor#check!) because this sits on the
    # spot gate's admission path.
    #
    # @return [RunningTurns::Reading]
    def running_turns
      # Table-qualified: .not_in_frozen_category left-joins `categories`, which
      # also has an `id`, and a bare `pluck(:id)` is ambiguous under it.
      ids = where(status: :running).pluck("sessions.id")
      return EMPTY if ids.empty?

      on_a_worker, queued = agent_turns_for(ids)
      between_jobs = ids.to_set - on_a_worker - queued
      asleep = ids_asleep_until_a_future_wake(between_jobs.to_a)

      Reading.new(
        on_a_worker: on_a_worker.size,
        awaiting_a_worker: queued.size + between_jobs.size - asleep.size,
        asleep: asleep.size
      )
    end

    private

    # Of these sessions, which have a turn a worker has started and which have
    # one merely queued. See PendingAgentTurns.split.
    #
    # Rescued toward "all of them are on a worker", which counts every row and
    # leaves nothing for the asleep probe to drop.
    def agent_turns_for(ids)
      PendingAgentTurns.split(ids)
    rescue StandardError => e
      Rails.logger.warn("[RunningTurns] Could not read the agents queue (#{e.class}: #{e.message}) — " \
        "treating every running turn as executing")
      [ ids.to_set, Set.new ]
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
    rescue StandardError => e
      Rails.logger.warn("[RunningTurns] Could not read pending wake-ups (#{e.class}: #{e.message}) — " \
        "counting every running turn")
      Set.new
    end
  end
end
