# frozen_string_literal: true

# Daily aggregate of how often the archive-side mass-deletion guard had to defuse
# a mangled clone.
#
# Background: an interrupted `rm -rf` on a live clone leaves a working tree that
# is nothing but deletions of tracked files. `CloneArtifactService` refuses to
# preserve such a tree (#411/#413), and `DeferredCloneCleanupJob` stamps
# `mangled_clone_dropped_deletions` / `mangled_clone_defused_at` on the session
# when it does.
#
# That refusal used to log at `.error`, which meant a GlitchTip event and a
# tripped "Zimmer backend logging errors" Grafana rule for every clone the guard
# *successfully* handled — nine pages in one afternoon for nine sessions that all
# archived fine (#415). The refusal is now a `.warn`, which keeps the
# per-occurrence line in VictoriaLogs without paging anyone.
#
# The frequency still matters: it is the live signal for #412, the non-atomic
# clone delete that mangles the trees in the first place. Zimmer ships no metrics
# pipeline (logs and errors only — see docs/operate/observability.md), so this job
# is the counter: one aggregate line per day, at `.warn` so it reaches
# VictoriaLogs, summing what the guard caught. One line a day is cheap to read and
# impossible to mistake for a page.
class MangledCloneReportJob < ApplicationJob
  include DatabaseRetry

  # Not `default`: this is a periodic reporter, and it belongs with the other
  # monitors on the isolated `pollers` scheduler so a backed-up `default` queue
  # cannot silence the visibility we have into #412.
  queue_as :pollers

  # Singleton — a duplicate run would double-report the same window.
  good_job_control_concurrency_with(
    key: -> { "mangled_clone_report" },
    total_limit: 1
  )

  # Matches the daily cron, so consecutive runs tile the timeline rather than
  # overlapping (a defusal counted twice would overstate the rate this exists to
  # measure).
  REPORT_WINDOW = 24.hours

  # Session ids are listed inline so an operator can go straight to one, but a bad
  # day could mangle dozens of clones and the line has to stay readable.
  SESSION_ID_DISPLAY_LIMIT = 20

  def perform
    since = REPORT_WINDOW.ago
    sessions = with_db_retry { defused_sessions(since).to_a }

    if sessions.empty?
      # INFO is not exported to VictoriaLogs, so a quiet day writes nothing there
      # — which is the correct reading of "no mangled clones". The line still
      # lands in the container log as proof the reporter ran.
      Rails.logger.info "[MangledCloneReportJob] No mangled clones defused in the last #{REPORT_WINDOW.inspect}"
      return
    end

    session_ids = sessions.map(&:id)
    total_dropped = sessions.sum { |s| s.metadata["mangled_clone_dropped_deletions"].to_i }
    shown = session_ids.first(SESSION_ID_DISPLAY_LIMIT)
    suffix = session_ids.size > shown.size ? " (+#{session_ids.size - shown.size} more)" : ""

    # .warn, not .error: every one of these is a landmine the guard already
    # defused. It reaches VictoriaLogs and Grafana for the rate, and pages no one.
    Rails.logger.warn(
      "[MangledCloneReportJob] Mass-deletion guard defused #{sessions.size} mangled clone(s) " \
      "in the last #{REPORT_WINDOW.inspect}, dropping #{total_dropped} tracked-file deletion(s). " \
      "Sessions: #{shown.join(', ')}#{suffix}. " \
      "Root cause is the non-atomic clone delete tracked in zimmer#412."
    )
  end

  private

  # Sessions whose clone the guard defused inside the window. The marker is only
  # ever written by DeferredCloneCleanupJob as an ISO8601 UTC string, so casting
  # it to a timestamp in SQL is safe and keeps the scan off Ruby.
  def defused_sessions(since)
    Session
      .where("metadata->>'mangled_clone_defused_at' IS NOT NULL")
      .where("(metadata->>'mangled_clone_defused_at')::timestamptz >= ?", since)
      .order(:id)
  end
end
