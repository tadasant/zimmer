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
      ].freeze

      # The three HealthMonitorService actions terminate processes and rewrite rows
      # in bulk, so they carry the same cooldown Api::V1::HealthController enforces
      # — literally the same object, so hammering one surface throttles the other
      # for this caller. The two CLI actions only enqueue a job (and are
      # unthrottled over REST), so they are not rate-limited here either.
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
        - **backfill_token_usage**: Queue a sweep of every transcript on disk into the token-spend
          ledger, so `get_costs` covers all of history rather than only spend since ingestion was
          deployed. The sweep normally starts itself after a deploy and needs nobody; use this to
          re-scan, or to restart one that stopped. Idempotent — it returns the run already in
          flight rather than starting a second, and ingestion upserts on the API request id, so a
          re-read directory writes no duplicate rows.
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
            description: "Why the queues are being halted. For enter_queue_recovery_mode."
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
          kill runaway sessions (`action_session`), or discard queued jobs by class from the
          GoodJob dashboard at `/jobs`. Call `exit_queue_recovery_mode` when done; calling
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
