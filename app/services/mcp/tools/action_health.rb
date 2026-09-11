# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors the maintenance actions of Api::V1::HealthController
    # (cleanup_processes, retry_sessions, archive_old) plus the two CLI
    # maintenance jobs from Api::V1::ClisController (refresh, clear_cache).
    class ActionHealth < Tool
      ACTIONS = %w[
        cleanup_processes retry_sessions archive_old cli_refresh cli_clear_cache
        enter_queue_recovery_mode exit_queue_recovery_mode backfill_token_usage
        run_post_deploy_tasks
        preview_queued_jobs discard_queued_jobs reschedule_queued_jobs
      ].freeze

      # The three HealthMonitorService actions terminate processes and rewrite rows
      # in bulk, so they carry the same cooldown Api::V1::HealthController enforces
      # — literally the same object, so hammering one surface throttles the other
      # for this caller. The two CLI actions only enqueue a job (and are
      # unthrottled over REST), so they are not rate-limited here either.
      #
      # Nor are the three queued-job actions, for the reason the queue recovery
      # mode pair is exempt and one more of their own. The cooldown fails CLOSED
      # when the cache is unavailable, and an overloaded instance is exactly when
      # the cache is least trustworthy — so it would lock the third cleanup lever
      # during the incident it exists for. And they carry a stronger throttle than
      # a timer: every mutating call must state the exact row count it expects, so
      # an accidental repeat of the same call refuses (the scope now holds zero
      # rows) rather than running twice.
      RATE_LIMITED_ACTIONS = %w[cleanup_processes retry_sessions archive_old].freeze
      DEFAULT_ARCHIVE_DAYS = 7
      MIN_ARCHIVE_DAYS = 1
      MAX_ARCHIVE_DAYS = 365

      tool_name "action_health"

      description <<~DESC
        Perform system health and maintenance actions.

        **Actions:**
        - **cleanup_processes**: Terminate orphaned agent processes
        - **retry_sessions**: Retry failed sessions (optionally specify session_ids)
        - **archive_old**: Archive sessions older than N days (requires "days", default 7)
        - **cli_refresh**: Trigger a background refresh of CLI tool installations
        - **cli_clear_cache**: Clear npm/pip caches and reinstall MCP packages
        - **enter_queue_recovery_mode**: Halt background job execution on the demand-side
          queues (`pollers`, `triggers`, `inference`, `maintenance`, `default`) so a runaway backlog can be investigated
          and cleaned up. The `agents` queue keeps running, so sessions still start and run.
          Accepts "reason" (free text, shown in the UI banner and the Slack alert) and
          "ttl_minutes" (auto-exit window, clamped, default #{(QueueRecoveryMode::DEFAULT_TTL / 60).to_i}).
          Calling it again while active extends the window. This is an INSTANCE-WIDE halt:
          everything except agent sessions stops until it is lifted.
        - **exit_queue_recovery_mode**: Resume normal background job processing.
        - **backfill_token_usage**: Queue a sweep of the ledger's whole history — every Claude Code
          transcript on disk, plus every other runtime's corpus in whatever form it takes (for Pi,
          the stored transcript of every Pi session; for Codex, every rollout under
          `~/.codex/sessions`) — so `get_costs` covers all of history rather than only spend since
          ingestion was deployed. The sweep normally starts itself after a deploy and needs nobody;
          use this to re-scan, or to restart one that stopped. Idempotent — it returns the run
          already in flight rather than starting a second, and ingestion upserts on the row's
          request id, so a re-read corpus writes no duplicate rows.
        - **preview_queued_jobs**: Count the queued jobs a maintenance call would act on,
          broken down by class and queue. Read-only. Scope it with "job_class" and/or
          "queue_name" — at least one is required. The `matched` number it returns is what the
          two actions below require as "expected_count".
        - **discard_queued_jobs**: Discard queued jobs scoped by "job_class" and/or "queue_name".
          **NOT RECOVERABLE** — the rows are marked finished with a DiscardJobError and the work
          never runs. Requires "expected_count" (a mismatch refuses and discards nothing) and is
          capped at #{QueuedJobMaintenance::MAX_PER_CALL} rows per call. Only rows that are
          unfinished, unstarted and unclaimed are eligible; finished history, running executions
          and the protected `#{QueuedJobMaintenance::PROTECTED_QUEUES.join(", ")}` queue are never
          touched. Reports what it discarded by class.
        - **reschedule_queued_jobs**: The reversible sibling of discard — moves the same scope's
          `scheduled_at` instead of ending it, so the work still happens and another call moves it
          back. Same scope, cap and "expected_count" rules. "delay_minutes" says how far out
          (default 0 = as soon as the queue allows, max
          #{(QueuedJobMaintenance::MAX_RESCHEDULE_DELAY / 60).to_i} minutes).
        - **run_post_deploy_tasks**: Re-arm any failed one-time post-deploy task (`db/post_deploy/`)
          and queue a run. These normally run themselves within a couple of minutes of a deploy and
          need nobody; use this when one has failed for a reason that has since been fixed, or when
          its retries are spent. Idempotent. Their current state is in `get_system_health` under
          `post_deploy_task_health`.

        Note: "queue recovery mode" is about the JOB QUEUES. It is unrelated to session
        recovery after a deploy or crash, and it never touches session state.

        Note: Health actions are rate-limited (30s cooldown between calls, per API key).
        The two queue recovery mode actions are exempt — the escape hatch, and especially
        the way back out of it, must work on the first try during an incident.
      DESC

      input_schema({
        type: "object",
        properties: {
          action: { type: "string", enum: ACTIONS, description: "Health action to perform." },
          session_ids: {
            type: "array",
            items: { type: "number" },
            description: "Session IDs to retry. For retry_sessions action."
          },
          days: {
            type: "number",
            minimum: 1,
            maximum: 365,
            description: "Archive sessions older than this many days. For archive_old action. Default: 7"
          },
          reason: {
            type: "string",
            description: "Why. Shown in the banner and the Slack alert for enter_queue_recovery_mode; " \
              "recorded on the discarded rows for discard_queued_jobs."
          },
          job_class: {
            type: "string",
            description: "Exact job class to scope to, e.g. \"GitHubPullRequestPollerJob\". For the " \
              "three *_queued_jobs actions; at least one of job_class / queue_name is required."
          },
          queue_name: {
            type: "string",
            description: "Exact queue to scope to, e.g. \"pollers\". For the three *_queued_jobs " \
              "actions; at least one of job_class / queue_name is required. The " \
              "#{QueuedJobMaintenance::PROTECTED_QUEUES.join(", ")} queue is refused."
          },
          expected_count: {
            type: "number",
            minimum: 0,
            description: "How many rows you expect to affect, from preview_queued_jobs. Required by " \
              "discard_queued_jobs and reschedule_queued_jobs; a mismatch refuses and changes nothing."
          },
          delay_minutes: {
            type: "number",
            minimum: 0,
            maximum: (QueuedJobMaintenance::MAX_RESCHEDULE_DELAY / 60).to_i,
            description: "How far out to push the rescheduled jobs, in minutes. For " \
              "reschedule_queued_jobs. Default 0 — as soon as the queue allows."
          },
          # Bounds read from the service rather than re-declared, so a change to
          # the window cannot leave this schema advertising the old one.
          ttl_minutes: {
            type: "number",
            minimum: (QueueRecoveryMode::MIN_TTL / 60).to_i,
            maximum: (QueueRecoveryMode::MAX_TTL / 60).to_i,
            description: "Auto-exit window in minutes. For enter_queue_recovery_mode. " \
              "Default: #{(QueueRecoveryMode::DEFAULT_TTL / 60).to_i}"
          }
        },
        required: [ "action" ]
      })

      def call(args)
        action = require_arg(args, :action)
        raise ToolError, "Unknown action \"#{action}\". Valid actions: #{ACTIONS.join(', ')}" unless ACTIONS.include?(action)

        raise ToolError, rate_limit_message(action) if rate_limited?(action)

        result = case action
        when "cleanup_processes" then cleanup_processes
        when "retry_sessions" then retry_sessions(args["session_ids"])
        when "archive_old" then archive_old(args["days"])
        when "cli_refresh" then cli_refresh
        when "cli_clear_cache" then cli_clear_cache
        when "enter_queue_recovery_mode" then enter_queue_recovery_mode(args)
        when "exit_queue_recovery_mode" then exit_queue_recovery_mode
        when "backfill_token_usage" then backfill_token_usage
        when "run_post_deploy_tasks" then run_post_deploy_tasks
        when "preview_queued_jobs" then preview_queued_jobs(args)
        when "discard_queued_jobs" then discard_queued_jobs(args)
        when "reschedule_queued_jobs" then reschedule_queued_jobs(args)
        end

        record_action(action)
        result
      end

      private

      def cleanup_processes
        results = HealthMonitorService.new.cleanup_orphaned_processes
        "## Processes Cleaned Up\n\n#{json_block(results)}"
      end

      def retry_sessions(session_ids)
        ids = Array(session_ids).map(&:to_i).presence
        results = HealthMonitorService.new.retry_failed_sessions(session_ids: ids)
        "## Sessions Retried\n\n#{json_block(results)}"
      end

      def archive_old(days)
        days = (days || DEFAULT_ARCHIVE_DAYS).to_i.clamp(MIN_ARCHIVE_DAYS, MAX_ARCHIVE_DAYS)
        results = HealthMonitorService.new.archive_old_sessions(older_than: days.days)
        "## Old Sessions Archived\n\n#{json_block(results)}"
      end

      def cli_refresh
        CliStatusRefreshJob.perform_later
        "## CLI Refresh Queued\n\n- **Message:** CLI status refresh queued"
      end

      def cli_clear_cache
        CacheClearJob.perform_later(reinstall: true)
        "## CLI Cache Clear Queued\n\n- **Message:** Cache clear queued. Caches will be cleared in the worker container and MCP packages reinstalled."
      end

      # The caller is very often the agent session that was started to look at the
      # backlog, so the response says in plain terms what is now halted, what is
      # not, and how long it has — an agent that does not know the window will not
      # think to extend it.
      def enter_queue_recovery_mode(args)
        status = QueueRecoveryMode.enter!(
          reason: args["reason"],
          ttl: args["ttl_minutes"].presence&.to_i&.minutes,
          actor: "MCP action_health"
        )

        <<~MD
          ## Queue Recovery Mode ON

          - **Halted queues:** #{QueueRecoveryMode::HALTED_QUEUES.join(", ")}
          - **Still running:** #{QueueRecoveryMode::LIVE_QUEUES.join(", ")} (agent sessions start and run normally, and interactive logins on /inference still work)
          - **Auto-exit at:** #{status.expires_at&.iso8601} (#{((status.expires_in || 0) / 60.0).ceil} min)

          Enqueued jobs are frozen, not discarded — they resume when the mode is lifted. To
          act on the cause: disable the stampeding Trigger (`action_trigger`), archive or
          kill runaway sessions (`action_session`), or thin the backlog itself with
          `preview_queued_jobs` then `discard_queued_jobs` / `reschedule_queued_jobs` on this
          same tool. Call `exit_queue_recovery_mode` when done; calling
          `enter_queue_recovery_mode` again extends the window.

          #{json_block(status)}
        MD
      rescue QueueRecoveryMode::NotAvailable => e
        raise ToolError, e.message
      end

      def exit_queue_recovery_mode
        status = QueueRecoveryMode.exit!(actor: "MCP action_health")

        "## Queue Recovery Mode OFF\n\nBackground job processing resumed on " \
          "#{QueueRecoveryMode::HALTED_QUEUES.join(", ")}.\n\n#{json_block(status)}"
      end

      # The MCP half of an ops action that has no shell equivalent: nothing about
      # loading the ledger's history requires access to the production box.
      def backfill_token_usage
        run = TokenUsageBackfill.request!(trigger: "manual")
        TokenUsageBackfillJob.perform_later

        "## Token Usage Backfill Queued\n\n" \
        "- **Run:** ##{run.id} (#{run.status}, trigger #{run.trigger})\n" \
        "- **Corpus:** #{run.transcript_root}\n" \
        "- **Progress:** #{run.directories_done}/#{run.directories_total} directories, " \
        "#{run.rows_written} rows written so far\n\n" \
        "It runs in slices on a five-minute cron and stops when the corpus is covered. " \
        "`get_costs` reports coverage as it advances.\n\n#{json_block(TokenUsageBackfill.coverage)}"
      end

      # The MCP half of the same ops action the health page button and
      # POST /api/v1/health/run_post_deploy_tasks take. One implementation
      # underneath, so the three surfaces cannot mean different things.
      def run_post_deploy_tasks
        result = PostDeployTask::Runner.request!
        outstanding = result[:total] - result[:succeeded]

        "## Post-Deploy Tasks Queued\n\n" \
        "- **Re-armed:** #{result[:rearmed]} failed task#{'s' unless result[:rearmed] == 1}\n" \
        "- **Outstanding:** #{outstanding} of #{result[:total]} recorded task#{'s' unless result[:total] == 1}" \
        "#{" (+#{result[:awaiting_first_tick]} never ticked)" if result[:awaiting_first_tick].positive?}\n" \
        "- **Blocked:** #{result[:blocked]} (failed and out of retries)\n\n" \
        "A pass runs every two minutes and works each task inside a 90-second budget; a task too " \
        "slow for one slice resumes on the next tick.\n\n#{json_block(result)}"
      end

      # The read the two mutating actions are driven from. Kept on this tool rather
      # than on `get_system_health` because the number it returns is an argument to
      # the next call, not a health signal: it has to be scoped exactly the way the
      # write will be, and read at the moment the write is about to happen.
      def preview_queued_jobs(args)
        preview = QueuedJobMaintenance.preview(
          job_class: args["job_class"],
          queue_name: args["queue_name"]
        )

        <<~MD
          ## Queued Jobs — #{preview.matched} eligible

          #{scope_line(preview)}
          - **By class:** #{counts_line(preview.by_job_class)}
          - **By queue:** #{counts_line(preview.by_queue)}

          Eligible means unfinished, unstarted and unclaimed. Finished history, running executions
          and the `#{QueuedJobMaintenance::PROTECTED_QUEUES.join(", ")}` queue are never included.
          #{"\n**Over the #{QueuedJobMaintenance::MAX_PER_CALL}-row cap** — narrow the scope before discarding or rescheduling.\n" if preview.over_cap?}
          To act on these, pass `expected_count: #{preview.matched}` to `discard_queued_jobs`
          (not recoverable) or `reschedule_queued_jobs` (reversible).

          #{json_block(preview)}
        MD
      rescue QueuedJobMaintenance::Refused => e
        raise ToolError, e.message
      end

      def discard_queued_jobs(args)
        result = QueuedJobMaintenance.discard!(
          job_class: args["job_class"],
          queue_name: args["queue_name"],
          expected_count: args["expected_count"],
          reason: args["reason"],
          actor: "MCP action_health"
        )

        maintenance_receipt(result, "Discarded", "Those jobs will never run — a discard is not recoverable.")
      rescue QueuedJobMaintenance::Refused => e
        raise ToolError, e.message
      end

      def reschedule_queued_jobs(args)
        result = QueuedJobMaintenance.reschedule!(
          job_class: args["job_class"],
          queue_name: args["queue_name"],
          expected_count: args["expected_count"],
          scheduled_at: args["delay_minutes"].presence&.to_i&.minutes&.from_now,
          actor: "MCP action_health"
        )

        maintenance_receipt(
          result, "Rescheduled",
          "Nothing was destroyed — the work runs at #{result.scheduled_at&.iso8601}, and another call moves it again."
        )
      rescue QueuedJobMaintenance::Refused => e
        raise ToolError, e.message
      end

      # One receipt shape for both mutating actions. The per-class breakdown is the
      # point: an operator reading the transcript back has to be able to see WHAT
      # was thrown away, not only how much.
      def maintenance_receipt(result, verb, note)
        <<~MD
          ## Queued Jobs #{verb} — #{result.affected} row#{"s" unless result.affected == 1}

          - **By class:** #{counts_line(result.by_job_class)}
          - **By queue:** #{counts_line(result.by_queue)}
          #{"- **Skipped:** #{result.skipped.size} row(s) that changed state mid-call\n" if result.skipped.any?}
          #{note}

          #{json_block(result)}
        MD
      end

      def scope_line(preview)
        parts = []
        parts << "job_class `#{preview.job_class}`" if preview.job_class.present?
        parts << "queue `#{preview.queue_name}`" if preview.queue_name.present?

        "- **Scope:** #{parts.join(", ")}"
      end

      def counts_line(counts)
        return "none" if counts.blank?

        counts.map { |key, count| "`#{key}` #{count}" }.join(", ")
      end

      def json_block(payload)
        "```json\n#{JSON.pretty_generate(payload.as_json)}\n```"
      end

      def cooldown
        @cooldown ||= HealthActionCooldown.new(context.caller_fingerprint)
      end

      def rate_limited?(action)
        return false unless RATE_LIMITED_ACTIONS.include?(action)

        cooldown.limited?(action)
      end

      def record_action(action)
        return unless RATE_LIMITED_ACTIONS.include?(action)

        cooldown.record(action)
      end

      # A null cache cannot enforce the cooldown, so `limited?` reports true and
      # the action is refused rather than run unthrottled. Say which it was —
      # "wait 30 seconds" is a lie the caller would act on by waiting forever.
      def rate_limit_message(action)
        unless cooldown.store_usable?
          # The model reads the raised message; an operator reads the log. Both
          # need to know this was a refusal, not a cooldown they can wait out.
          Rails.logger.error("[mcp action_health] refusing #{action}: the cache cannot enforce the cooldown")
          return "Rate limiting unavailable: the cache is unavailable, so the " \
            "#{HealthActionCooldown::COOLDOWN.to_i}-second cooldown cannot be enforced. " \
            "Refusing to run health maintenance actions."
        end

        "Rate limited: please wait #{HealthActionCooldown::COOLDOWN.to_i} seconds between health actions."
      end
    end
  end
end
