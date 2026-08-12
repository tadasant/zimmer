# frozen_string_literal: true

# Daily aggregate of how often the archive-side mass-deletion guard has to defuse
# a mangled clone.
#
# An interrupted `rm -rf` on a live clone leaves a working tree that is nothing
# but deletions of tracked files. `CloneArtifactService` refuses to preserve such
# a tree (#411/#413) and `DeferredCloneCleanupJob` stamps the two keys below on
# the session when it does.
#
# That refusal is self-healing, so it logs at `.warn` — routing it through
# `StructuredLogger#error` reported one GlitchTip event and one Grafana-rule ERROR
# per clone the guard *successfully* handled (#415). The frequency still matters:
# it is the live signal for #412, the non-atomic clone delete that mangles the
# trees in the first place. Zimmer ships no metrics pipeline (logs and errors
# only — see docs/operate/observability.md), so this job is the counter: one
# aggregate line a day, at `.warn` so it reaches VictoriaLogs, summing what the
# guard caught. One line a day is cheap to read and impossible to mistake for a
# page.
class MangledCloneReportJob < ApplicationJob
  include DatabaseRetry

  # A periodic reporter belongs with the other monitors on the isolated `pollers`
  # scheduler rather than on `default`, where a backlog of session work would
  # delay it.
  queue_as :pollers

  # Singleton — a duplicate run would report the same window twice.
  good_job_control_concurrency_with(
    key: -> { "mangled_clone_report" },
    total_limit: 1
  )

  # The session-metadata keys `DeferredCloneCleanupJob` writes and this job reads.
  # They live here, on the reader, because a rename that touched only the writer
  # would leave both test suites green while permanently zeroing the report.
  DEFUSED_AT_KEY = "mangled_clone_defused_at"
  DROPPED_DELETIONS_KEY = "mangled_clone_dropped_deletions"

  # An hour wider than the daily cron, deliberately. `REPORT_WINDOW.ago` is
  # measured when the run starts, not when cron fired, so a window that exactly
  # matched the interval would drop everything in the gap whenever a run started
  # late (a deploy, a busy scheduler, a retry) — a silent undercount in the one
  # signal this job exists to preserve. The cost is the opposite error: a defusal
  # inside the overlap can appear in two consecutive reports. An occasional
  # double-count is visible in the lines themselves; a gap is invisible.
  REPORT_WINDOW = 25.hours

  # Session ids are listed inline so an operator can go straight to one, but a bad
  # day can mangle dozens of clones and the line has to stay readable.
  SESSION_ID_DISPLAY_LIMIT = 20

  def perform
    defused = with_db_retry { defused_sessions(REPORT_WINDOW.ago) }

    if defused.empty?
      # INFO is below the OTLP export threshold, so a quiet day writes nothing to
      # VictoriaLogs — which is the correct reading of "no mangled clones". The
      # line still lands in the container log as proof the reporter ran.
      Rails.logger.info "[MangledCloneReportJob] No mangled clones defused in the last #{REPORT_WINDOW.inspect}"
      return
    end

    session_ids = defused.map(&:first)
    total_dropped = defused.sum { |(_id, dropped)| dropped.to_i }
    shown = session_ids.first(SESSION_ID_DISPLAY_LIMIT)
    suffix = session_ids.size > shown.size ? " (+#{session_ids.size - shown.size} more)" : ""

    # .warn, not .error: every one of these is a landmine the guard already
    # defused. It reaches VictoriaLogs and Grafana for the rate, and pages no one.
    #
    # "session(s)", not "clone(s)": the marker is one key per session, so a
    # session archived twice inside the window contributes once.
    Rails.logger.warn(
      "[MangledCloneReportJob] Mass-deletion guard defused a mangled clone for #{session_ids.size} session(s) " \
      "in the last #{REPORT_WINDOW.inspect}, dropping #{total_dropped} tracked-file deletion(s). " \
      "Sessions: #{shown.join(', ')}#{suffix}. " \
      "Root cause is the non-atomic clone delete tracked in zimmer#412."
    )
  end

  private

  # `[[session_id, dropped_deletions], ...]` for the clones defused inside the
  # window, ordered by id.
  #
  # The timestamps are compared as strings rather than cast to `timestamptz`. Both
  # sides are fixed-width ISO8601 UTC (`%Y-%m-%dT%H:%M:%SZ`), so lexicographic
  # order is chronological order — and unlike a cast, a stray value in this
  # free-form `metadata` column cannot raise `PG::InvalidDatetimeFormat` and take
  # the whole report down with it.
  #
  # `pluck`, not `find_each`: `sessions.transcript` is the largest column on the
  # table, and this needs an id and an integer.
  # The key names are interpolated rather than bound: they are frozen constants,
  # and a bind parameter on the left of `->>` leaves Postgres unable to resolve
  # which overload of the operator is meant. A row with no marker (or no metadata
  # at all) yields NULL, and `NULL >= …` is NULL, so it drops out of the result
  # without needing a separate IS NOT NULL guard.
  def defused_sessions(since)
    Session
      .where("metadata->>'#{DEFUSED_AT_KEY}' >= ?", since.utc.iso8601)
      .order(:id)
      .pluck(:id, Arel.sql("metadata->>'#{DROPPED_DELETIONS_KEY}'"))
  end
end
