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
          *in_flight_lines(report),
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

      # What the backlog is MADE OF, and WHERE it is old — not just how deep.
      #
      # `system_health` below already carries `ready_count`, and a bare count
      # cannot tell a starved queue from a busy one — Zimmer's seven queues have
      # very different thread counts and job durations. It also carries
      # `oldest_ready_age_seconds`, which is the number the Grafana `GoodJob queue
      # is not draining` rule reads, taken across every queue at once; the
      # per-queue ages are what turn that page into an answer, because a two-thread
      # lane in front of jobs that block for a minute holds its head of line for
      # tens of minutes with a perfectly healthy worker. The Slack backlog page
      # carries the same split, and this is the tool an agent triaging that page
      # actually has: the GoodJob dashboard needs a browser session on the
      # production host, which an agent session does not have. Without it the
      # agent-facing surface answers a strictly weaker question than the
      # human-facing one.
      #
      # Read from `ready_backlog_breakdown` directly rather than folded into
      # `full_health_report`: that report also serves GET /api/v1/health and the
      # /health page, which render far more often than anyone asks this question.
      #
      # Silent when nothing is waiting — a breakdown of an empty queue is a line
      # of noise on every healthy call. But NOT silent when the read fails: these
      # are three scans of `good_jobs`, and the caller most likely to hit a
      # database that cannot serve them is the one triaging a database that is
      # struggling. Saying so beats raising and losing the whole health report.
      def ready_backlog_lines
        breakdown = HealthMonitorService.new.ready_backlog_breakdown
        return [] if breakdown[:by_queue].blank?

        [
          "- **Ready backlog by queue:** #{HealthMonitorService.format_breakdown(breakdown[:by_queue])}",
          "- **Ready backlog by job class:** #{HealthMonitorService.format_breakdown(breakdown[:by_job_class])}",
          "- **Oldest ready by queue:** #{HealthMonitorService.format_ages(breakdown[:oldest_by_queue])}",
          *head_of_line_line(breakdown[:head_of_line])
        ]
      rescue StandardError => e
        Rails.logger.warn("[GetSystemHealth] Could not read the backlog breakdown: #{e.message}")
        [ "- **Ready backlog breakdown:** unavailable (#{e.class})" ]
      end

      # What the worker is HOLDING, per lane — the half of the picture the ready
      # backlog cannot supply.
      #
      # An agent triaging a stalled lane has exactly two questions after the lines
      # above: is that lane's pool full, and how long has its oldest execution been
      # running. Full pool plus an old execution is a wedge; ready work with no
      # claim at all is a lane the worker has stopped polling. They demand opposite
      # responses and the ready-side numbers are identical in both, so an agent that
      # cannot see these has to guess — which is what happened on 2026-09-04, when
      # `inference`, `default` and `maintenance` claimed nothing for over an hour
      # behind a live worker and no surface could say which shape it was.
      #
      # Read off the report already in hand rather than re-querying: unlike the
      # ready breakdown these are free, since `queue_statistics` computes them on
      # every health read.
      #
      # Silent when nothing is executing, matching `ready_backlog_lines` — an
      # in-flight breakdown of an idle worker is a line of noise on every healthy
      # call.
      def in_flight_lines(report)
        stats = report.dig(:system_health, :queue_stats) || {}
        by_queue = stats[:claimed_count_by_queue]
        return [] if by_queue.blank?

        [
          "- **In flight by queue:** #{HealthMonitorService.format_breakdown(by_queue)} " \
            "(threads: #{HealthMonitorService.format_breakdown(HealthMonitorService.lane_thread_counts)})",
          "- **Oldest execution by queue:** " \
            "#{HealthMonitorService.format_ages(stats[:oldest_claimed_age_seconds_by_queue])}"
        ]
      end

      # The single row the alerts fire on, named. The Slack page renders the same
      # lane and job class inline on its first bullet; this is the half of that
      # parity the ages line cannot carry, and it is the more useful half here —
      # the reader is an agent with no route to /jobs, so the job class is the only
      # way it learns WHAT is waiting rather than merely where.
      def head_of_line_line(head)
        return [] if head.blank?

        [
          "- **Head of line:** #{head[:queue]} / #{head[:job_class]}, " \
            "waiting #{HealthMonitorService.format_wait(head[:age_seconds])}"
        ]
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
