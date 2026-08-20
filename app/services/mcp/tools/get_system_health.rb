# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors GET /api/v1/health (Api::V1::HealthController#show), optionally
    # folding in GET /api/v1/clis/status (Api::V1::ClisController#status) — the
    # two reports an operator needs to tell "the system is unhealthy" apart from
    # "a CLI fell out of auth".
    class GetSystemHealth < Tool
      tool_name "get_system_health"

      description <<~DESC
        Get the system health report for the Zimmer.

        Returns system health information including session counts, job queue status, and system metrics.
        Optionally include CLI tool installation status.

        **Use cases:**
        - Monitor system health and performance
        - Check for stuck sessions or failed jobs
        - Verify CLI tools are properly installed
      DESC

      input_schema({
        type: "object",
        properties: {
          include_cli_status: {
            type: "boolean",
            description: "Include CLI tool installation status. Default: false"
          }
        },
        required: []
      })

      def call(args)
        report = HealthMonitorService.new.full_health_report

        lines = [
          "## System Health Report",
          "",
          "- **Timestamp:** #{Time.current.iso8601}",
          "- **Environment:** #{Rails.env}",
          "- **Ruby Version:** #{RUBY_VERSION}",
          *queue_recovery_mode_lines,
          *ready_backlog_lines,
          "",
          "### Health Details",
          "```json",
          JSON.pretty_generate(report.as_json),
          "```"
        ]

        lines.concat(cli_status_lines) if args["include_cli_status"]

        lines.join("\n")
      end

      private

      # What the backlog is MADE OF, not just how deep it is.
      #
      # `system_health` below already carries `ready_count`, and a bare count
      # cannot tell a starved queue from a busy one — Zimmer's four queues have
      # very different thread counts and job durations. The Slack backlog page
      # carries this same split for exactly that reason, and this is the tool an
      # agent triaging that page actually has: the GoodJob dashboard needs a
      # browser session on the production host, which an agent session does not
      # have. Leaving it out here would reproduce, on the agent-facing surface,
      # the gap the alert change closes on the human-facing one.
      #
      # Read from `ready_backlog_breakdown` directly rather than folded into
      # `full_health_report`: that report also serves GET /api/v1/health and the
      # /health page, which render far more often than anyone asks this question.
      #
      # Silent when nothing is waiting — a breakdown of an empty queue is a line
      # of noise on every healthy call.
      def ready_backlog_lines
        breakdown = HealthMonitorService.new.ready_backlog_breakdown
        return [] if breakdown[:by_queue].blank?

        [
          "- **Ready backlog by queue:** #{format_counts(breakdown[:by_queue])}",
          "- **Ready backlog by job class:** #{format_counts(breakdown[:by_job_class])}"
        ]
      end

      def format_counts(counts)
        counts.map { |name, count| "#{name} #{count}" }.join(", ")
      end

      # Stated up front, and stated in BOTH directions. A pending queue depth means
      # something completely different depending on whether the queues are
      # deliberately halted — a caller that reads "500 pending jobs" without this
      # line will diagnose an outage that is actually an operator's escape hatch.
      # An explicit "Off" rather than an absent line, so a caller asking "are the
      # queues halted?" can tell "no" from "this report doesn't say".
      def queue_recovery_mode_lines
        status = QueueRecoveryMode.status

        unless status.active?
          return [ "- **Queue Recovery Mode:** Off (background jobs processing normally)" ]
        end

        [
          "- **⏸ QUEUE RECOVERY MODE IS ON.** Job execution is halted on " \
          "#{QueueRecoveryMode::HALTED_QUEUES.join(", ")}; #{QueueRecoveryMode::LIVE_QUEUES.join(", ")} " \
          "still runs. Pending-job counts below are frozen, not backing up. " \
          "Auto-exit at #{status.expires_at&.iso8601}." +
            (status.reason.present? ? " Reason: #{status.reason}" : "")
        ]
      end

      # CLI status is a secondary section: a failure reading it degrades this
      # section rather than throwing away the health report the caller asked for.
      def cli_status_lines
        [
          "",
          "### CLI Status",
          "- **Unauthenticated CLIs:** #{CliStatusService.unauthenticated_count}",
          "",
          "```json",
          JSON.pretty_generate(CliStatusService.cached_report.as_json),
          "```"
        ]
      rescue StandardError => e
        [ "", "*Could not fetch CLI status: #{e.message}*" ]
      end
    end
  end
end
