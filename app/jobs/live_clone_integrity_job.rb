# frozen_string_literal: true

# Hourly check that every live session still has the working tree it is running
# in.
#
# Why this exists
# ---------------
# On 2026-09-02 three sessions lost their clones inside five minutes. The state
# was trivially visible on disk — a clone directory holding nothing but the
# runtime scaffolding Zimmer writes into it (`.mcp.json`, `.claude/`, the stderr
# log), with the git tree and `.git` gone — and nothing told anyone. The only
# signal that reached a human was two `ForkSessionService` errors from sessions
# that happened to be forking off the victims at the time, which is to say: the
# incident was found by accident (zimmer#808, zimmer#811).
#
# `MangledCloneReportJob` is the neighbouring reporter and deliberately does not
# cover this. It counts what the *archive-side* mass-deletion guard defused, from
# markers `DeferredCloneCleanupJob` writes; a clone destroyed under a running
# session never reaches that guard and leaves no marker. This one looks at the
# filesystem instead.
#
# What counts as damage
# ---------------------
# Only what has no benign explanation — a detector that cries wolf is a detector
# somebody mutes:
#
#   * A clone directory that exists but has lost its git tree. There is no benign
#     way for a tracked working tree to disappear from underneath a live session,
#     and this is the exact state found on disk after the incident.
#   * A clone that has lost the session's agent root subdirectory, which is fatal
#     on its own: `air prepare` writes `<clone>/<subdirectory>/.mcp.json` and dies
#     with ENOENT.
#
# A clone root that is **gone entirely** is deliberately NOT reported, for any
# status. A session legitimately sits on a deleted clone between an archive and
# the resume that re-clones it, and `Session#deliver_follow_up!` flips a session
# to `running` *before* it enqueues the job whose recreate path rebuilds the
# clone — so on the congested afternoon this job exists for, `running` with no
# clone root is a normal, minutes-to-hours-long state. That case is not silent
# anyway: the session fails with "clone directory not found", which is already an
# error somebody sees.
#
# A scaffolded fork clone (`clone_scaffolded`) is exempt from the git-tree check:
# it was created empty on purpose, and its `git init` is best-effort. It is not
# exempt from the subdirectory check — ForkSessionService creates the working
# directory explicitly, so its absence is damage there too.
class LiveCloneIntegrityJob < ApplicationJob
  include DatabaseRetry

  # With the other monitors on the isolated `pollers` scheduler, so a backlog of
  # session work cannot delay the one job that would notice a session losing its
  # working tree.
  queue_as :pollers

  good_job_control_concurrency_with(
    key: -> { "live_clone_integrity" },
    total_limit: 1
  )

  # A bad hour can damage many clones and the line has to stay readable.
  DISPLAY_LIMIT = 20

  def perform
    damaged = with_db_retry { candidates }.filter_map { |session| damage_for(session) }

    if damaged.empty?
      # INFO is below the OTLP export threshold, so a healthy hour writes nothing
      # to VictoriaLogs. The line still lands in the container log as proof the
      # check ran.
      Rails.logger.info "[LiveCloneIntegrityJob] Every live session's clone is intact"
      return
    end

    shown = damaged.first(DISPLAY_LIMIT)
    suffix = damaged.size > shown.size ? " (+#{damaged.size - shown.size} more)" : ""

    # `.error`, deliberately: this is uncommitted work already destroyed, on a
    # session that is still running against the hole. It reaches VictoriaLogs and
    # the `zimmer_backend_log_errors` alert, which is the surface that was silent
    # when this last happened.
    Rails.logger.error(
      "[LiveCloneIntegrityJob] #{damaged.size} live session(s) have lost their working tree: " \
      "#{shown.join('; ')}#{suffix}. A clone was deleted or stripped underneath a live session " \
      "(zimmer#808); the session's uncommitted work is gone."
    )
  end

  private

  def candidates
    Session
      .where(status: Session::NON_REAPABLE_STATUSES)
      .where("metadata->>'clone_path' IS NOT NULL")
      .order(:id)
      .pluck(:id, :status, :subdirectory,
             Arel.sql("metadata->>'clone_path'"),
             Arel.sql("metadata->>'clone_scaffolded'"))
      .map do |(id, status, subdirectory, clone_path, scaffolded)|
        { id: id, status: Session.status_label(status), subdirectory: subdirectory, clone_path: clone_path,
          scaffolded: scaffolded.to_s == "true" }
      end
  end

  # A one-line description of what is wrong with this session's clone, or nil
  # when nothing is.
  def damage_for(session)
    path = session[:clone_path].to_s
    return nil if path.blank?
    # A clone root that is simply absent is a session waiting to be re-cloned.
    # See the class comment.
    return nil unless File.directory?(path)

    if !session[:scaffolded] && !File.exist?(File.join(path, ".git"))
      surviving = surviving_entries(path)
      return "session #{session[:id]} (#{session[:status]}): #{path} has no .git " \
        "(#{surviving.empty? ? "empty" : "left: #{surviving.join(', ')}"})"
    end

    if session[:subdirectory].present? && !File.directory?(File.join(path, session[:subdirectory]))
      return "session #{session[:id]} (#{session[:status]}): agent root #{session[:subdirectory]} " \
        "is missing from #{path}"
    end

    nil
  rescue SystemCallError => e
    "session #{session[:id]} (#{session[:status]}): could not inspect #{session[:clone_path]} (#{e.class})"
  end

  # What is still in the stripped directory, which is the detail that identifies
  # the failure: a tree holding only Zimmer's own runtime scaffolding is the
  # zimmer#808 signature.
  def surviving_entries(path, limit: 8)
    entries = Dir.children(path).sort
    entries.size > limit ? entries.first(limit) + [ "…" ] : entries
  rescue SystemCallError
    []
  end
end
