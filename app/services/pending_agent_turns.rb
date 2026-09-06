# frozen_string_literal: true

# Which of these sessions already has an AgentSessionJob queued or running.
#
# Every repair sweep that considers re-enqueuing a turn has to ask this first,
# because the two wrong answers are asymmetric. Miss a job that is merely late
# and the sweep enqueues a second one, which is a duplicated turn against one
# clone and real quota spent re-delivering a prompt. Report a job that no longer
# exists and the sweep stands down on a session nothing will ever start — the
# failure the sweeps exist to end.
#
# GoodJob is read directly rather than through `sessions.running_job_id`, and the
# difference matters for exactly the population these sweeps look at:
# `running_job_id` is written from INSIDE `AgentSessionJob#perform`, so a session
# whose start job is sitting in the queue — or was deferred with a delay — has a
# blank one and reads as abandoned. The job row is the durable fact.
#
# `serialized_params -> 'arguments' ->> 0` is the session id every AgentSessionJob
# is enqueued with, on every one of its four enqueue helpers, and only the ids
# come back: the rest of the payload is a deferred prompt with its attachments,
# which there is no reason to load.
module PendingAgentTurns
  module_function

  # @param ids [Array<Integer>] session ids to ask about
  # @return [Set<Integer>] the subset that has an unfinished AgentSessionJob
  def for(ids)
    reading = split(ids)
    reading.on_a_worker | reading.queued | reading.scheduled
  end

  # One reading of the `agents` queue for a set of sessions, split by what is
  # actually happening to each turn.
  #
  # `scheduled` is deliberately its own bucket rather than part of `queued`. A job
  # with a future `scheduled_at` is a spot-gate re-check or a clone-retry backoff:
  # a turn somebody deliberately parked, whose owner is the thing that parked it,
  # not the worker pool. Counting it as "queued for a worker" would put every
  # spot-held session into the /inference queue figure and name GoodJob as the
  # resume owner of a session the spot ladder owns.
  Reading = Data.define(:on_a_worker, :queued, :scheduled)

  # The same population, told apart by whether a worker has actually PICKED THE
  # TURN UP — `performed_at` — the job is sitting ready in the `agents` queue
  # waiting for a free thread, or it is parked on a future `scheduled_at`.
  #
  # The sweeps do not care about that difference: a turn is coming either way,
  # and enqueuing a second one is the mistake — which is why {.for} unions all
  # three. RunningTurns does care, because it is measuring how much of the
  # fleet's capacity is in use, and the `agents` lane is only
  # ConnectionBudget.good_job_queue_threads[:agents] deep. See
  # tadasant/zimmer#957.
  #
  # @param ids [Array<Integer>] session ids to ask about
  # @param now [Time] the instant a `scheduled_at` is judged future against
  # @return [Reading]
  def split(ids, now: Time.current)
    return Reading.new(on_a_worker: Set.new, queued: Set.new, scheduled: Set.new) if ids.empty?

    rows = GoodJob::Job
      .where(job_class: AgentSessionJob.name, finished_at: nil)
      .where("serialized_params -> 'arguments' ->> 0 IN (?)", ids.map(&:to_s))
      .pluck(Arel.sql("serialized_params -> 'arguments' ->> 0"), :performed_at, :scheduled_at)

    started = Set.new
    queued = Set.new
    scheduled = Set.new
    rows.each do |session_id, performed_at, scheduled_at|
      id = session_id.to_i
      if performed_at.present?
        started << id
      elsif scheduled_at.present? && scheduled_at > now
        scheduled << id
      else
        queued << id
      end
    end

    # A session with two unfinished jobs — a re-check racing a recovery — is on a
    # worker if either of them is, and ready-queued beats parked for the same
    # reason: the buckets are ranked by how close the turn is to running.
    Reading.new(on_a_worker: started, queued: queued - started,
                scheduled: scheduled - started - queued)
  end

  # The same question as an anti-join, for a caller that wants the sessions with
  # nothing queued rather than the ids of those with something.
  #
  # A sweep that reads a bounded page of candidates and *then* discards the ones
  # with a job pending has a starvation mode the set form cannot fix: a discarded
  # session advances no timestamp, so it keeps its place at the head of an
  # oldest-first ordering and can fill the whole page. Under the congested queue
  # this sweep exists for — 251 ready jobs on 2026-08-22 — that is exactly when
  # the page fills with sessions whose jobs are merely late. Filtering in SQL
  # means the page only ever contains rows worth acting on.
  #
  # @param relation [ActiveRecord::Relation<Session>] must select from `sessions`
  # @return [ActiveRecord::Relation<Session>]
  def without_a_pending_turn(relation)
    relation.where(
      "NOT EXISTS (SELECT 1 FROM good_jobs WHERE good_jobs.job_class = ? " \
      "AND good_jobs.finished_at IS NULL " \
      "AND good_jobs.serialized_params -> 'arguments' ->> 0 = sessions.id::text)",
      AgentSessionJob.name
    )
  end
end
