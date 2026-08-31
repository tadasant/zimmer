# frozen_string_literal: true

# One row per one-time post-deploy task: has it run, when, how far did it get,
# and did it fail.
#
# The row is created the first time `PostDeployTask::Runner` sees the task file,
# so a task that has never had a chance to run is visible as `pending` rather
# than as an absence nobody can tell apart from "not written yet". It is never
# deleted: the ledger is the answer to "was this applied to this environment",
# and that answer has to outlive the task file being tidied away.
#
# LIFECYCLE
#
#   pending   → nobody has finished it. Either it has never run, or it ran and
#               asked to be resumed on the next tick (see `cursor`).
#   running   → a worker holds it right now. `locked_at` is the lease; a worker
#               killed mid-task leaves this state behind, and `reap_expired_leases!`
#               is what turns that into an ordinary failure.
#   succeeded → done. Terminal, and the reason a deploy costs one indexed lookup
#               rather than re-running everything ever written.
#   failed    → raised. Retried with backoff until RETRY_DELAYS is spent, then it
#               sits here until a human asks for it again from the health page,
#               the REST API or `action_health`.
#
# The status is also the mutex. `claim!` is a conditional UPDATE, so two
# containers coming up at once cannot both run the same task: one wins the row,
# the other sees zero affected rows and moves on.
class PostDeployTaskRun < ApplicationRecord
  STATUSES = %w[pending running succeeded failed].freeze

  # Backoff between failed attempts. Short at the start — a task that tripped on
  # a transient database blip should recover unattended — and finite at the end:
  # a task failing for a durable reason must stop burning a worker slice every
  # tick and start being visible as something a human has to look at. Five
  # entries means six failures over roughly two hours before it goes quiet.
  RETRY_DELAYS = [ 1.minute, 5.minutes, 15.minutes, 30.minutes, 1.hour ].freeze

  # How long a claim is honoured before another runner may reclaim the row.
  # Comfortably longer than any single slice (PostDeployTaskJob::SLICE_BUDGET),
  # so this only ever fires for a worker that actually died.
  LEASE = 20.minutes

  class LeaseExpired < StandardError; end

  validates :version, presence: true, uniqueness: true
  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :outstanding, -> { where.not(status: "succeeded") }
  scope :in_version_order, -> { order(:version) }

  class << self
    # The row for a task, created on first sight. `create_or_find_by!` rather
    # than `find_or_create_by!` because the racing callers here are two
    # containers booting together, and the unique index — not a read — is what
    # decides which one wins.
    def ledger_for(task_class)
      create_or_find_by!(version: task_class.version) do |run|
        run.name = task_class.task_name
      end
    end

    # Turn abandoned claims back into ordinary failures.
    #
    # A worker killed mid-task (a deploy, an OOM, a SIGKILL) leaves its row
    # `running` with nobody working it. Rather than teaching every other query to
    # special-case that, convert it once per tick into the state it actually is —
    # a failure — so the normal backoff, the normal retry budget and the normal
    # "this is stuck" escalation all apply without a second code path.
    #
    # The guard is re-stated in the UPDATE so a runner that lost the race to
    # another reaper does not overwrite a claim taken in the meantime.
    def reap_expired_leases!(now: Time.current)
      where(status: "running").where(locked_at: ..(now - LEASE)).find_each do |run|
        run.finish_failure!(LeaseExpired.new(
          "the worker holding this task stopped without finishing it " \
          "(claimed #{run.locked_by || 'unknown'} at #{run.locked_at&.iso8601})"
        ), now: now, guard_status: "running")
      end
    end

    # Everything the health panel, the REST API, the MCP tool and the Supervisor
    # dashboard say about post-deploy tasks. One object, so the four surfaces
    # cannot drift into claiming different things — the same discipline
    # `TokenUsageBackfill.coverage` applies to the Costs page.
    def summary(registered: PostDeployTask::Registry.all)
      runs = in_version_order.to_a
      known_versions = runs.map(&:version).to_set
      registered_versions = registered.map(&:version).to_set

      counts = STATUSES.index_with { |s| runs.count { |r| r.status == s } }
      blocked = runs.count(&:blocked?)

      {
        status: health_status(counts, blocked),
        total: runs.size,
        pending: counts["pending"],
        running: counts["running"],
        succeeded: counts["succeeded"],
        failed: counts["failed"],
        blocked: blocked,
        # A task file that exists but has no ledger row yet: the runner has not
        # ticked since this deploy. Counted so the panel can say "about to run"
        # rather than silently omitting it.
        awaiting_first_tick: registered.count { |t| known_versions.exclude?(t.version) },
        tasks: runs.map { |r| r.as_summary(registered: registered_versions.include?(r.version)) }
      }
    end

    private

    def health_status(counts, blocked)
      if blocked.positive?
        HealthMonitorService::HealthStatus.new(
          status: :critical,
          message: "#{blocked} post-deploy task#{'s' unless blocked == 1} failed and out of retries"
        )
      elsif counts["failed"].positive?
        HealthMonitorService::HealthStatus.new(
          status: :warning,
          message: "#{counts['failed']} post-deploy task#{'s' unless counts['failed'] == 1} failing, retry pending"
        )
      else
        HealthMonitorService::HealthStatus.new(status: :healthy, message: "No post-deploy tasks outstanding")
      end
    end
  end

  def succeeded? = status == "succeeded"
  def failed? = status == "failed"
  def running? = status == "running"

  # A failed task with its retries spent. It will not run again until someone
  # asks, which is exactly the state the health panel escalates on.
  def blocked? = failed? && next_attempt_at.nil?

  # Should this tick try to work the row? The SQL in `claim!` says the same
  # thing; this is the cheap read that keeps the runner from attempting a claim
  # it cannot win.
  def due?(now: Time.current)
    return false if succeeded?
    return false if running?
    return next_attempt_at.present? && next_attempt_at <= now if failed?

    true
  end

  # Take the row, or return false because somebody else already has it.
  #
  # A single conditional UPDATE, so the database arbitrates rather than a
  # read-then-write that two containers can both believe they won.
  def claim!(owner:, now: Time.current)
    claimed = self.class
      .where(id: id, status: %w[pending failed])
      .where("status <> 'failed' OR (next_attempt_at IS NOT NULL AND next_attempt_at <= ?)", now)
      .update_all(
        status: "running",
        attempts: Arel.sql("attempts + 1"),
        started_at: Arel.sql("COALESCE(started_at, #{self.class.connection.quote(now)})"),
        locked_at: now,
        locked_by: owner,
        last_ran_at: now,
        updated_at: now
      )

    return false if claimed.zero?

    reload
    true
  end

  def finish_success!(now: Time.current)
    update!(
      status: "succeeded", finished_at: now, last_ran_at: now,
      failures: 0, next_attempt_at: nil, last_error: nil, last_error_at: nil,
      locked_at: nil, locked_by: nil
    )
  end

  # The task asked to be resumed. Back to `pending` with the lease released, so
  # the next tick — or a different container — picks it straight up. `failures`
  # is reset because the slice did not fail: progress is progress, and a task
  # that ran for six hours in three-minute slices must not exhaust a budget
  # meant for things that are broken.
  def finish_continue!(now: Time.current)
    update!(
      status: "pending", last_ran_at: now, failures: 0, next_attempt_at: nil,
      last_error: nil, last_error_at: nil, locked_at: nil, locked_by: nil
    )
  end

  # The task raised, or its worker died holding it. Recorded, backed off, and —
  # once the delays are spent — parked with `next_attempt_at` nil, which is what
  # `blocked?` reads and what turns the health panel critical.
  #
  # `guard_status` narrows the write to a row still in the state the caller
  # observed, for the reaper: two runners can both spot the same abandoned lease.
  def finish_failure!(error, now: Time.current, guard_status: nil)
    next_failures = failures + 1
    delay = RETRY_DELAYS[next_failures - 1]

    attrs = {
      status: "failed", last_ran_at: now, failures: next_failures,
      last_error: format_error(error), last_error_at: now,
      next_attempt_at: delay && now + delay,
      locked_at: nil, locked_by: nil, updated_at: now
    }

    if guard_status
      written = self.class.where(id: id, status: guard_status).update_all(attrs)
      return false if written.zero?

      reload
      true
    else
      update!(attrs.except(:updated_at))
    end
  end

  # Re-arm a failed task from a surface a human can reach without a shell.
  # Idempotent, and a no-op on one that already succeeded — re-running a
  # succeeded task is what writing a new task file is for.
  def rearm!
    return false if succeeded?

    update!(status: "pending", failures: 0, next_attempt_at: nil, locked_at: nil, locked_by: nil)
    true
  end

  def as_summary(registered: true)
    {
      version: version,
      name: name,
      status: status,
      registered: registered,
      attempts: attempts,
      failures: failures,
      blocked: blocked?,
      stats: stats,
      started_at: started_at,
      finished_at: finished_at,
      last_ran_at: last_ran_at,
      next_attempt_at: next_attempt_at,
      last_error: last_error,
      last_error_at: last_error_at
    }
  end

  private

  # First line plus the application frames, capped. The whole backtrace goes to
  # the logs; what belongs in a column rendered on a dashboard is enough to tell
  # one failure from another.
  def format_error(error)
    frames = Array(error.try(:backtrace)).grep(/#{Regexp.escape(Rails.root.to_s)}/).first(5)
    [ "#{error.class}: #{error.message}", *frames ].join("\n").truncate(4000)
  end
end
