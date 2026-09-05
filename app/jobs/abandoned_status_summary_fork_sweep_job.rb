# frozen_string_literal: true

# Archives a status-summary fork that was created and then never given its turn.
#
# **The gap this closes.** SessionStatusSummaryHarvestJob states the invariant —
# "The fork is archived even when nothing usable came back. A fork left behind
# holds a full copy of a repository" — and every route to it is keyed to a fork
# that RAN. Harvest is enqueued from SessionStateMachine's `pause` and `fail`
# hooks; a fork is created directly in `needs_input` (ForkSessionService) and
# only reaches `running` when SessionStatusSummaryGenerator hands it its prompt,
# so a fork that never got the prompt never transitions and never harvests.
# StatusSummaryBackstopJob repairs the SOURCE session and scopes forks out
# explicitly. CleanupOrphanedSessionsJob takes `running` orphans and sessions
# carrying `paused_by: "recovery"`, and an undispatched fork is neither. Zimmer
# session 8582 sat in that hole for seven days holding a repository clone.
#
# **What "never ran and never will" means here, and why the predicate is narrow.**
# The failure mode of getting this wrong is silent — a session that quietly
# disappears — so this sweep asks for age AND positive evidence rather than
# either alone:
#
# - It is a status-summary fork. Ordinary sessions are never in scope; the scope
#   used is the exact negation of the one every operator list hides forks with.
# - It is at rest in `needs_input` or `waiting`. A `running` fork is somebody
#   else's problem (CleanupOrphanedSessionsJob), and `failed` already harvests.
# - It is older than ABANDONED_AFTER. The gap between creating a fork and
#   prompting it is a few statements in one method, so hours of it is not a slow
#   dispatch, it is a dispatch that never happened.
# - Nothing is in flight for it: no `running_job_id`, no
#   `pending_follow_up_prompt`, and no unfinished AgentSessionJob naming it
#   (PendingAgentTurns' anti-join). The first two are written by
#   Session#deliver_follow_up! before it returns, so either one present means the
#   prompt DID reach the fork. The anti-join is the one that carries the weight,
#   for the reason PendingAgentTurns states: `running_job_id` is written from
#   inside the job, so a turn that was enqueued with a DELAY has a blank one and
#   reads as abandoned.
# - It is not dormant on purpose. StalledSessionStart::DORMANT_MARKERS is the
#   list, shared rather than re-derived, and a spot hold is why this matters
#   most: SpotSessionHold#hold! takes custody of the held turn — it REMOVES
#   `pending_follow_up_prompt` and `return_to_queue!` clears `running_job_id` —
#   leaving a fork in `waiting`, with no own transcript, that is legitimately
#   waiting to run. Under sustained spot pressure that can be a long wait, and
#   #712 is the open issue that forks compete for that capacity at all. Reaping
#   one is precisely the silent failure this predicate exists to avoid.
# - It is not asleep on an armed wake. Belt to the markers' braces, asked per
#   candidate because the candidate set is tiny, and fail-safe: an unreadable
#   trigger table reads as "asleep on purpose".
# - Its transcript holds nothing past the fork point. This is the same
#   comparison SessionStatusSummaryHarvestJob#extracted_summary makes to decide
#   the fork wrote nothing of its own, so both paths agree on what a turn is.
#   Raw line count against a parsed message index errs the safe way: blank or
#   unparseable lines inflate the left side, so the test gets HARDER to satisfy,
#   never easier.
#
# **Why it only archives.** The stranded `pending` claim on the source session's
# summary record is already owned: SessionStatusSummary#pending? treats a claim
# past PENDING_TIMEOUT as debris, and StatusSummaryBackstopJob names "the claim
# abandoned past PENDING_TIMEOUT" as one of the cases it repairs. The fork is
# the only thing with no owner, so this sweep gives it one and touches nothing
# else — no summary writes, no re-forking, no headless retries queued onto the
# `inference` lane behind a fleet-wide outage.
class AbandonedStatusSummaryForkSweepJob < ApplicationJob
  include SingletonSweep
  queue_as :default

  # How long a fork must have gone undispatched before this sweep will believe
  # it never will be. Deliberately far beyond any plausible dispatch delay:
  # SessionStatusSummaryGenerator#call creates the fork and calls
  # `deliver_follow_up!` on it a few statements later, so the real window is
  # milliseconds and anything past a single-digit number of hours is a fork
  # whose generator run died in between. A fork left alive one extra hour costs
  # a clone; a live one reaped costs work nobody can see was lost.
  ABANDONED_AFTER = 6.hours

  # Rows examined per sweep. In steady state the candidate set is empty — a
  # dispatched fork is `running` within milliseconds of being created — so this
  # only bites on a backlog, and a backlog is drained a sweep at a time rather
  # than in one long transaction.
  SCAN_LIMIT = 200

  def perform
    reaped = candidates.select { |fork| never_dispatched?(fork) }.select { |fork| archive(fork) }

    return if reaped.empty?

    Rails.logger.info(
      "[AbandonedStatusSummaryForkSweepJob] Archived #{reaped.size} undispatched status-summary fork(s): " \
      "#{reaped.map(&:id).join(', ')}"
    )
  end

  private

  # The cheap half of the predicate, in SQL. Everything here is a fact about the
  # row; the transcript comparison that decides whether the fork ever took a
  # turn is asked in Ruby, over this much smaller set.
  def candidates
    relation = Session
      .not_in_frozen_category
      .status_summary_forks
      .where(status: [ :needs_input, :waiting ])
      .where(created_at: ...ABANDONED_AFTER.ago)
      .where(running_job_id: nil)
      .where("sessions.metadata->>'pending_follow_up_prompt' IS NULL")

    relation = StalledSessionStart::DORMANT_MARKERS.reduce(relation) do |scope, marker|
      scope.where("sessions.metadata->>? IS NULL", marker)
    end

    PendingAgentTurns.without_a_pending_turn(relation).order(created_at: :asc).limit(SCAN_LIMIT)
  end

  # Positive evidence that this fork never received the one prompt it exists to
  # answer, and is not resting on purpose.
  #
  # `forked_at_message_index` is required rather than defaulted: it is written by
  # ForkSessionService on every fork, so its absence means this row is not a fork
  # this sweep understands, and a fork it does not understand is one it leaves
  # alone.
  def never_dispatched?(fork)
    fork_point = fork.metadata&.dig("forked_at_message_index")
    return false unless fork_point.is_a?(Integer)
    return false if fork.awaiting_scheduled_wake?

    fork.transcript_line_count <= fork_point + 1
  end

  # True when the fork ended up archived, which is what the log line counts.
  def archive(fork)
    fork.logs.create!(
      content: "Archiving a status-summary fork that was created #{((Time.current - fork.created_at) / 3600).round} " \
               "hours ago and never received its summary prompt.",
      level: "warning"
    )
    fork.archive_actor = "Zimmer's status-summary fork cleanup (never dispatched)"
    fork.archive! if fork.may_archive?
    fork.archived?
  rescue StandardError => e
    Rails.logger.error(
      "[AbandonedStatusSummaryForkSweepJob] Failed to archive undispatched summary fork #{fork.id}: #{e.message}"
    )
    false
  end
end
