# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors the maintenance actions of Api::V1::HealthController
    # (cleanup_processes, retry_sessions, archive_old) plus the two CLI
    # maintenance jobs from Api::V1::ClisController (refresh, clear_cache).
    class ActionHealth < Tool
      ACTIONS = %w[cleanup_processes retry_sessions archive_old cli_refresh cli_clear_cache].freeze

      # The three HealthMonitorService actions terminate processes and rewrite rows
      # in bulk, so they carry the same cooldown Api::V1::HealthController enforces
      # — and share its cache keys, so hammering one surface throttles the other.
      # The two CLI actions only enqueue a job (and are unthrottled over REST), so
      # they are not rate-limited here either.
      RATE_LIMITED_ACTIONS = %w[cleanup_processes retry_sessions archive_old].freeze
      COOLDOWN = 30.seconds
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

        Note: Health actions are rate-limited (30s cooldown between calls).
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
          }
        },
        required: [ "action" ]
      })

      def call(args)
        action = require_arg(args, :action)
        raise ToolError, "Unknown action \"#{action}\". Valid actions: #{ACTIONS.join(', ')}" unless ACTIONS.include?(action)

        raise ToolError, rate_limit_message if rate_limited?(action)

        result = case action
        when "cleanup_processes" then cleanup_processes
        when "retry_sessions" then retry_sessions(args["session_ids"])
        when "archive_old" then archive_old(args["days"])
        when "cli_refresh" then cli_refresh
        when "cli_clear_cache" then cli_clear_cache
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

      def json_block(payload)
        "```json\n#{JSON.pretty_generate(payload.as_json)}\n```"
      end

      def rate_limited?(action)
        return false unless RATE_LIMITED_ACTIONS.include?(action)

        last_run = Rails.cache.read(rate_limit_key(action))
        return false unless last_run

        Time.current - last_run < COOLDOWN
      end

      def record_action(action)
        return unless RATE_LIMITED_ACTIONS.include?(action)

        Rails.cache.write(rate_limit_key(action), Time.current, expires_in: COOLDOWN + 1.second)
      end

      def rate_limit_key(action)
        "health_api_rate_limit:#{action}"
      end

      def rate_limit_message
        "Rate limited: please wait #{COOLDOWN.to_i} seconds between health actions."
      end
    end
  end
end
