# frozen_string_literal: true

# Works the pending one-time post-deploy tasks, within a budget.
#
# Called once per cron tick by `PostDeployTaskJob`, and directly by the health
# page / REST / MCP "run now" action. Everything about running a task lives here
# so those callers cannot disagree about what running one means.
#
# THREE PROPERTIES THIS HAS TO HAVE
#
#  1. **A task never runs twice.** `succeeded` is terminal, and the ledger row is
#     claimed with a conditional UPDATE, so two containers booting together see
#     one winner and one no-op. Note what this does *not* promise: a task that
#     died halfway may have half-applied. Idempotency inside `up` is the task
#     author's job, exactly as with a data migration.
#
#  2. **It never wedges.** Each task is worked inside its own rescue, so a task
#     that raises is recorded and the next one still runs. The whole pass is
#     bounded by a deadline, so a slow task hands its worker thread back rather
#     than holding it. And nothing in the deploy waits on any of this — the
#     runner is a cron job in the worker, not an entrypoint step.
#
#  3. **A failure is visible without a shell.** Recorded on the row, counted in
#     `PostDeployTaskRun.summary`, and rendered by the health page, the REST
#     health report, `get_system_health` and the Supervisor dashboard.
class PostDeployTask
  class Runner
    Result = Struct.new(:version, :name, :outcome, :error, keyword_init: true)

    # Outcomes, in the vocabulary the callers report in:
    #   :succeeded  — ran to completion, will never run again
    #   :continued  — asked to be resumed on the next tick
    #   :failed     — raised; recorded, backed off, retried
    #   :contended  — another worker holds it; nothing to do
    OUTCOMES = %i[succeeded continued failed contended].freeze

    # The operator action behind the health page button, POST
    # /api/v1/health/run_post_deploy_tasks and `action_health`'s
    # `run_post_deploy_tasks` — one implementation, so the three cannot mean
    # different things.
    #
    # Re-arms every failed task (including the ones whose retries are spent, which
    # is the state that needs a human in the first place) and enqueues a pass.
    # Enqueued rather than run inline: a pass may take a minute and a half, which
    # is not something to hold an HTTP request or an MCP call open for.
    #
    # Idempotent. Pressing it twice re-arms the same rows and enqueues a job the
    # concurrency guard drops.
    def self.request!(rearm_failed: true)
      rearmed = if rearm_failed
        PostDeployTaskRun.outstanding.select(&:failed?).count(&:rearm!)
      else
        0
      end

      PostDeployTaskJob.perform_later

      { rearmed: rearmed, enqueued: true }.merge(PostDeployTaskRun.summary)
    end

    def initialize(budget: nil, owner: default_owner, logger: Rails.logger, registry: Registry)
      @budget = budget
      @owner = owner
      @logger = logger
      @registry = registry
    end

    # Returns one Result per task it touched. An empty array is the steady state
    # — everything has succeeded and there is nothing to do.
    def call
      deadline = @budget ? Time.current + @budget : nil

      PostDeployTaskRun.reap_expired_leases!

      results = []

      # An explicit loop rather than `filter_map`: the budget check has to be
      # able to stop the pass, and `break` out of a block would discard the
      # results already collected.
      @registry.all.each do |entry|
        break if deadline && Time.current >= deadline

        run = PostDeployTaskRun.ledger_for(entry)
        next unless run.due?

        results << work(entry, run, deadline)
      end

      results
    end

    private

    def work(entry, run, deadline)
      return Result.new(version: entry.version, name: entry.task_name, outcome: :contended) \
        unless run.claim!(owner: @owner)

      @logger.info("[PostDeployTask] running #{entry.version} #{entry.task_name} (attempt #{run.attempts})")

      outcome = entry.task_class.new(run: run, deadline: deadline, logger: @logger).up

      if outcome == PostDeployTask::CONTINUE
        run.finish_continue!
        @logger.info("[PostDeployTask] #{entry.version} #{entry.task_name} yielded, will resume")
        Result.new(version: entry.version, name: entry.task_name, outcome: :continued)
      else
        run.finish_success!
        @logger.info("[PostDeployTask] #{entry.version} #{entry.task_name} complete")
        Result.new(version: entry.version, name: entry.task_name, outcome: :succeeded)
      end
    # A deploy interrupting a slice is not a task failure. Let it out unrecorded:
    # the row stays `running` and `reap_expired_leases!` converts it once the
    # lease is up, which is the same path a hard-killed worker takes.
    rescue GoodJob::InterruptError
      raise
    rescue StandardError => e
      run.finish_failure!(e)
      @logger.error("[PostDeployTask] #{entry.version} #{entry.task_name} failed: #{e.class}: #{e.message}")
      Rails.error.report(e, handled: true, context: { post_deploy_task: entry.version })
      Result.new(version: entry.version, name: entry.task_name, outcome: :failed, error: e)
    end

    # Who holds the lease. Enough to tell two containers apart in the Supervisor
    # row when a claim looks stuck.
    def default_owner = "#{Socket.gethostname}:#{Process.pid}"
  end
end
