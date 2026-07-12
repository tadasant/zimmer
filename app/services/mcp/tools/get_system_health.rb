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
