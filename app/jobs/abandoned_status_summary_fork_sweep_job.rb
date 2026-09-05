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
# - Nothing is queued for it in `enqueued_messages` either. That is a separate
#   carrier from the two above, and SpotSessionHold's queue-behind-a-scheduled-
#   turn path uses it: it moves the summary prompt into the queue and clears
#   `pending_follow_up_prompt` in the same breath, so the queue is the only
#   remaining evidence the turn exists. Archiving over it strands a `caller`-
#   origin message, which pages.
# - It is quiet by `updated_at` as well as old by `created_at`, the way both
#   sibling sweeps bound their populations. Age is a fact about when the row was
#   born; every marker below is written and cleared by something else, so
#   `updated_at` is what keeps a fork out of reach during the window between a
#   marker being cleared and the next thing being written.
# - It is not dormant on purpose. StrandedSleepRescue::DORMANT_MARKERS is the
#   list — the longer of the two, because its fifth marker (`deliberate_sleep_at`)
#   covers the one route into `waiting` that arms nothing and marks nothing else.
#   A spot hold is why this clause matters most: SpotSessionHold#hold! takes
#   custody of the held turn — it REMOVES `pending_follow_up_prompt`, and
#   `return_to_queue!` clears `running_job_id` — leaving a fork in `waiting`,
#   with no transcript of its own, that is legitimately waiting to run. Under
#   sustained spot pressure that wait can outlast ABANDONED_AFTER, and #712 is
#   the open issue that forks compete for that capacity at all. Reaping one is
#   precisely the silent failure this predicate exists to avoid.
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
  #
  # The two Ruby-side clauses are asked AFTER this page is read, so a row they
  # discard keeps its place at the head of an oldest-first ordering — the
  # head-of-line problem PendingAgentTurns.without_a_pending_turn's own header
  # describes. The only population that could accumulate there is forks that DID
  # run and were somehow never archived by harvest, which fires on both hooks; a
  # limit this far above any plausible number of them is what keeps the scan
  # bounded without letting them fill it.
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
      # Quiet by `updated_at` too, the way both sibling sweeps bound their
      # populations. Age alone is a fact about when the row was BORN, and every
      # marker below is written and cleared by something else — so a fork whose
      # markers are cleared on its way into a turn would be reapable in the
      # window between the clear and the next write. `updated_at` closes that
      # class of race in one clause, and costs the true target nothing: a fork
      # that was never dispatched has not been written to since `prepare_fork`.
      .where(updated_at: ...ABANDONED_AFTER.ago)
      .where(running_job_id: nil)
      .where("sessions.metadata->>'pending_follow_up_prompt' IS NULL")
      # Something is already on its way to this fork. SpotSessionHold's
      # queue-behind-a-scheduled-turn path puts the summary prompt here and
      # clears `pending_follow_up_prompt` in the same breath, so the queue is
      # the only remaining evidence that a turn exists — and archiving over a
      # `caller`-origin message strands it, which pages.
      .where("NOT EXISTS (SELECT 1 FROM enqueued_messages WHERE enqueued_messages.session_id = " \
             "sessions.id AND enqueued_messages.status = 'pending')")

    relation = StrandedSleepRescue::DORMANT_MARKERS.reduce(relation) do |scope, marker|
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
  #
  # The reason is written AFTER the archive, not before it. An archive that
  # raises leaves the fork a candidate for the next sweep, and a reason line
  # written first would then be re-written every hour — a timeline claiming an
  # archive that never happened, once per pass, forever.
  def archive(fork)
    fork.archive_actor = "Zimmer's status-summary fork cleanup (never dispatched)"
    fork.archive!
    fork.logs.create!(
      content: "Archived a status-summary fork that was created #{((Time.current - fork.created_at) / 3600).round} " \
               "hours ago and never received its summary prompt.",
      level: "warning"
    )
    fork.archived?
  rescue StandardError => e
    Rails.logger.error(
      "[AbandonedStatusSummaryForkSweepJob] Failed to archive undispatched summary fork #{fork.id}: #{e.message}"
    )
    false
  end
end
