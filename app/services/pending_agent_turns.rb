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
    return Set.new if ids.empty?

    GoodJob::Job
      .where(job_class: AgentSessionJob.name, finished_at: nil)
      .where("serialized_params -> 'arguments' ->> 0 IN (?)", ids.map(&:to_s))
      .pluck(Arel.sql("serialized_params -> 'arguments' ->> 0"))
      .map(&:to_i)
      .to_set
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
