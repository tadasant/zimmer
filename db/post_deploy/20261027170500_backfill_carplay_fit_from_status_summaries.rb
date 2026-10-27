# frozen_string_literal: true

# Marks the CarPlay fit of every session already resting in `needs_input` when
# this deploy lands, from the status summary each one already has.
#
# From this deploy on, the status-summary fork answers the CarPlay-fit question
# in the same turn as the blurb, so a session is marked every time it comes to
# rest. The sessions on the board at deploy time rested BEFORE that, and most of
# them will not rest again for days — a walkthrough waiting on a laptop stays
# parked until its human gets to one. Without this, the first drive after the
# deploy would find an untagged board, which is the state the feature exists to
# end. One short classification per session, over the blurb that is already
# stored (CarplayFitClassifier), leaves each blurb exactly as it was.
#
# It ships with the deploy because AGENTS.md ("ops actions ship with the deploy")
# leaves no other route: nobody has a shell on the production box. Its answer is
# in `post_deploy_task_runs` — on /health, in `GET /api/v1/health`, from
# `get_system_health` and at /supervisor/post_deploy_task_runs — and the marks
# themselves are on the board, in `get_user_view` and under the dashboard's
# "CarPlay fit" filter.
#
# IDEMPOTENT. The sweep only visits sessions with no mark, and the job it
# enqueues checks again before it writes, so a second run of this task, a retry
# after a slice died, or a human marking a row first are all no-ops for that
# row. Enqueued rather than classified inline: each classification is a
# `claude -p` call of up to a minute, and the 90-second slice budget is for
# walking rows, not for inference. The `inference` lane runs them behind the
# summary jobs that share its budget.
class BackfillCarplayFitFromStatusSummaries < PostDeployTask
  # Every session a driver could be shown that nobody has judged: resting on a
  # human, not Zimmer's own bookkeeping, with a blurb to read and no mark.
  # `carplay_fit IS NULL` rather than the "current" scope on purpose — a stale
  # mark was still a judgement someone made, and the fork rewrites it at the
  # next rest; this task is for the rows that were never judged at all.
  def self.candidates
    Session.excluding_status_summary_forks
      .where(status: :needs_input, carplay_fit: nil)
      .joins(:status_summary)
      .where(session_status_summaries: { state: "ready" })
      .where.not(session_status_summaries: { summary: [ nil, "" ] })
      .order(:id)
  end

  def up
    enqueued = stats["enqueued"].to_i

    outcome = sweep(self.class.candidates, batch_size: 100) do |batch|
      batch.each { |session| CarplayFitBackfillJob.perform_later(session.id) }
      enqueued += batch.size
      checkpoint!(enqueued: enqueued)
    end

    checkpoint!(enqueued: enqueued)
    outcome
  end
end
