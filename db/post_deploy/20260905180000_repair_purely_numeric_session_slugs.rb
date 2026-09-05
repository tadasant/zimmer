# frozen_string_literal: true

# Renames any session whose slug is all digits, so that no slug shadows a session
# id (https://github.com/tadasant/zimmer/issues/731).
#
# THE POINT OF THIS FILE: `Session.locate` reads an all-digit identifier as an id
# and never retries it as a slug, and `slug_is_not_purely_numeric` refuses to
# write a new one. Both are forward-only. A row that already holds such a slug is
# the one case where consolidating the fourteen ad-hoc lookups onto `locate`
# changes a reachable answer for the worse: `find_by(slug: "728")` used to return
# that row on four REST endpoints, and `locate` returns session #728 instead — a
# stranger, on endpoints that include `DELETE /api/v1/sessions/:id`.
#
# Such a row is unaddressable either way. `to_param` puts the slug in a URL, and
# the web UI's own lookup already read a numeric `:id` as an id before consulting
# slugs, so `/sessions/728` never reached it. Renaming is what makes it reachable
# rather than what breaks it.
#
# `Session#generate_slug_from_title!` cannot produce an all-digit slug — it always
# appends a `-YYYYMMDD-HHMM` stamp — so any row here was written through the
# caller-supplied `slug` on the REST create/update or on the MCP `start_session`
# tool, which the column's `/\A[a-z0-9-]+\z/` format validation permitted. The
# expected count is zero. That is the point: this deployment offers no shell to
# run the query from (AGENTS.md, "No production box access"), so "zero" has to be
# an answer a human can read rather than an assumption the PR made.
# `post_deploy_task_runs` is where they read it — on /health, in
# `GET /api/v1/health`, from `get_system_health`, and at
# /supervisor/post_deploy_task_runs.
#
# The new slug is the old one plus the stamp the generator would have appended,
# which is both a valid slug and the format every other slug in the table has.
# A session with no `created_at` — impossible through the model, cheap to survive
# anyway — keeps its slug and is counted as skipped rather than renamed to
# something arbitrary.
#
# IDEMPOTENT. The relation is `slug ~ '^[0-9]+$'`, and a renamed row no longer
# matches it, so a second run sweeps an empty set. A slice that dies mid-run has
# committed whichever rows it already renamed; the rest are still in the relation.
class RepairPurelyNumericSessionSlugs < PostDeployTask
  # Rows per slice. The per-row work is one `UPDATE` plus its validations, and the
  # expected population is zero, so this is about bounding the pathological case
  # rather than about throughput.
  BATCH_SIZE = 100

  # How many suffixed candidates to try before giving up on one row. The same
  # bound `generate_slug_from_title!` keeps, for the same reason: a row that
  # cannot find a free slug is left alone and counted, never retried forever.
  MAX_CANDIDATES = 25

  # Bounded, because `stats` is rendered verbatim in four places and the ledger
  # row is never deleted. The log carries every rename; this is the copy reachable
  # without a shell.
  MAX_DETAILED = 20

  def up
    @renamed = stats["rows_renamed"].to_i
    @skipped_by_reason = Hash.new(0).merge(stats["skipped_by_reason"] || {})
    @details = Array(stats["renamed_details"])

    outcome = sweep(Session.where("slug ~ '^[0-9]+$'"), batch_size: BATCH_SIZE) do |batch|
      batch.each { |session| repair(session) }
      stage_progress
    end

    stage_progress
    checkpoint!
    outcome
  end

  private

  def repair(session)
    return skip(session, "row_has_no_created_at") if session.created_at.blank?

    slug = free_slug_for(session)
    return skip(session, "no_free_slug_within_#{MAX_CANDIDATES}_candidates") if slug.nil?

    was = session.slug
    session.update!(slug: slug)
    @renamed += 1
    logger.info("[RepairPurelyNumericSessionSlugs] session ##{session.id}: #{was.inspect} -> #{slug.inspect}")
    @details << { session_id: session.id, was: was, now: slug } if @details.size < MAX_DETAILED
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    # A slug claimed between the read and the write, or any other validation the
    # row was already failing. Leaving it alone costs exactly what the status quo
    # costs; failing the task would leave every later row unrepaired.
    skip(session, "write_rejected")
    logger.warn("[RepairPurelyNumericSessionSlugs] session ##{session.id} not renamed: #{e.class} - #{e.message}")
  end

  # The old slug plus the stamp the generator would have appended, suffixed on
  # collision exactly as `generate_slug_from_title!` suffixes.
  def free_slug_for(session)
    base = "#{session.slug}-#{session.created_at.strftime('%Y%m%d-%H%M')}"

    MAX_CANDIDATES.times do |n|
      candidate = n.zero? ? base : "#{base}-#{n}"
      return candidate unless Session.exists?(slug: candidate)
    end

    nil
  end

  def skip(session, reason)
    @skipped_by_reason[reason] += 1
    logger.info("[RepairPurelyNumericSessionSlugs] session ##{session.id} skipped — #{reason}")
  end

  def stage_progress
    run.stats = run.stats.merge(
      "rows_renamed" => @renamed,
      "rows_skipped" => @skipped_by_reason.values.sum,
      "skipped_by_reason" => @skipped_by_reason,
      "renamed_details" => @details
    )
  end
end
