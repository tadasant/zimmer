# frozen_string_literal: true

# Stamps the back-reference on every session that was replaced before Zimmer
# started writing one (https://github.com/tadasant/zimmer/issues/801).
#
# WHAT THIS IS AND IS NOT. The refusal that stops a superseded session being
# resumed does NOT depend on this task: `Session#claim_system_recovery_turn!`
# queries the replacement side (`custom_metadata->>'replaces_session'`, now
# indexed), which every existing replacement already carries. So nothing here is
# load-bearing for correctness. What it repairs is READABILITY — session 11924
# still shows nothing pointing at 11931, so a human opening its page, or an agent
# reading it through `get_session`, is told nothing about where the work went.
# Sessions replaced from now on are stamped at creation by
# `Session#stamp_replaced_session_back_reference`; this is the same stamp,
# applied backwards.
#
# It ships with the deploy because AGENTS.md ("ops actions ship with the deploy")
# leaves no other route: nobody has a shell on the production box. Its answer is
# in `post_deploy_task_runs` — on /health, in `GET /api/v1/health`, from
# `get_system_health` and at /supervisor/post_deploy_task_runs.
#
# IDEMPOTENT. The stamp is skipped when the replaced session already carries a
# `replaced_by_session` naming the same replacement, so a second run is a no-op
# and a run that died halfway resumes without re-stamping what it finished. The
# sweep walks replacements in id order from a cursor, so it is resumable across
# slices.
#
# ONE STAMP PER REPLACED SESSION. A session replaced more than once (a
# replacement that itself failed and was replaced) keeps the LAST stamp written,
# which is the newest replacement — the sweep runs in ascending id order, so the
# most recent replacement is the one that lands. That matches what the live
# stamp does, where each new replacement overwrites the previous notice.
class StampReplacedSessionBackReferences < PostDeployTask
  # Every session that records having replaced another. Served by
  # `index_sessions_on_replaces_session`, so the tail of the sweep — the query
  # that proves there is nothing left — stays cheap.
  def self.candidates
    Session.where("custom_metadata->>'replaces_session' IS NOT NULL").order(:id)
  end

  def up
    stamped = stats["stamped"].to_i
    already = stats["already_stamped"].to_i
    unresolvable = stats["unresolvable"].to_i

    outcome = sweep(self.class.candidates, batch_size: 200) do |batch|
      batch.each do |replacement|
        case stamp(replacement)
        when :stamped then stamped += 1
        when :already then already += 1
        else unresolvable += 1
        end
      end

      checkpoint!(stamped: stamped, already_stamped: already, unresolvable: unresolvable)
    end

    checkpoint!(stamped: stamped, already_stamped: already, unresolvable: unresolvable)
    outcome
  end

  private

  # @return [Symbol] :stamped, :already, or :unresolvable
  def stamp(replacement)
    replaced_id = replacement.replaces_session_id
    # Covers a value that is not an id at all, and one naming the session itself
    # — `Session#replaces_session_id` refuses both rather than guessing.
    return :unresolvable if replaced_id.nil?

    replaced = Session.find_by(id: replaced_id)
    # A replacement naming a session that has since been deleted. Counted, not
    # an error: there is nothing left to stamp and nothing to fix.
    return :unresolvable if replaced.nil?

    # The same writer the live callback uses, so a backfilled notice and a
    # freshly stamped one are the same thing — including its idempotency check,
    # which is what makes a second run of this task a no-op.
    #
    # `at:` is the replacement's creation time, not now: the handoff happened
    # then, and a backfill stamping today's date would make a months-old handoff
    # look like it happened during the deploy.
    return :already unless replaced.record_replaced_by!(replacement, at: replacement.created_at)

    logger.info(
      "[StampReplacedSessionBackReferences] session #{replaced.id} was replaced by #{replacement.id}"
    )
    :stamped
  end
end
