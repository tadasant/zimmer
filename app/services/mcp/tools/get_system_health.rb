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

        Returns system health information including session counts, job queue status, system metrics,
        and which store `${VAR}` secrets resolve from. Optionally include CLI tool installation status.

        **Use cases:**
        - Monitor system health and performance
        - Check for stuck sessions or failed jobs
        - Verify CLI tools are properly installed
        - Check whether the Parameter Store namespace migration has finished before dropping the
          pre-rename read path. The "Secret Store" section names the canonical namespace, any
          pre-rename namespaces still being read, and the variable NAMES still answering from them.
          Names only — no secret value is ever returned.
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
          *ready_backlog_lines(report),
          *in_flight_lines(report),
          *cron_freshness_lines(report),
          *inbound_event_lines(report),
          "",
          "### Health Details",
          "```json",
          JSON.pretty_generate(report.as_json),
          "```",
          *secret_store_lines
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
      # Read off the report already in hand rather than re-queried. A second read of
      # `good_jobs` for this section would be three more scans of a table that is
      # largest precisely during the backlog this tool is being called to explain,
      # and its answers could disagree with the ones in the JSON below, taken a
      # moment earlier. Every number here comes from the single grouped read
      # `queue_statistics` already makes for the `critical` gate, so the section
      # costs nothing and the prose and the JSON describe the same instant.
      #
      # Silent when nothing is waiting — a breakdown of an empty queue is a line
      # of noise on every healthy call.
      def ready_backlog_lines(report)
        stats = report.dig(:system_health, :queue_stats) || {}
        by_queue = stats[:ready_count_by_queue]
        return [] if by_queue.blank?

        [
          "- **Ready backlog by queue:** #{HealthMonitorService.format_breakdown(by_queue)}",
          "- **Ready backlog by job class:** " \
            "#{HealthMonitorService.format_breakdown(stats[:ready_count_by_job_class])}",
          "- **Oldest ready by queue:** " \
            "#{HealthMonitorService.format_ages(stats[:oldest_ready_age_seconds_by_queue])}",
          *head_of_line_line(stats[:head_of_line])
        ]
      end

      # What the worker is HOLDING, per lane and per job class — the half of the
      # picture the ready backlog cannot supply.
      #
      # An agent triaging a stalled lane has exactly two questions after the lines
      # above: is that lane's pool full, and how long has its work been running.
      # A full pool whose YOUNGEST execution is already old is a wedge — every
      # thread held by work that is not coming back. Ready work with no claim at
      # all is the opposite: a lane the worker has stopped polling. An old oldest
      # beside a fresh youngest is neither, just one slow job. All three look
      # identical from the ready side, so an agent that cannot see these has to
      # guess — which is what happened on 2026-09-04, when `inference`, `default`
      # and `maintenance` picked up nothing for over an hour behind a live worker
      # and no surface could say which shape it was.
      #
      # The by-class line is the one that separates a flood from a wedge: the ready
      # split says which class is WAITING, this says which class is not finishing.
      #
      # Read off the report already in hand rather than re-querying: `queue_stats`
      # computes all of these on every health read.
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
          "- **In flight by job class:** " \
            "#{HealthMonitorService.format_breakdown(stats[:claimed_count_by_job_class])}",
          "- **Oldest execution by queue:** " \
            "#{HealthMonitorService.format_ages(stats[:oldest_claimed_age_seconds_by_queue])}",
          "- **Youngest execution by queue:** " \
            "#{HealthMonitorService.format_ages(stats[:youngest_claimed_age_seconds_by_queue])}"
        ]
      end

      # Which cron keys have stopped producing jobs, and why — the answer to the
      # "Cron schedule stale" page, and to "is sweep X still running?" without one.
      #
      # Always one line, like the queue recovery mode line: "every key on schedule" is
      # an answer, and an absent line is not. The keys that are behind are listed with
      # their reasons, including the `overdue` ones the page does not speak for, so an
      # agent can tell a hung sweep from one queued behind a backlog. Every key's full
      # reading is in `cron_health` in the JSON below.
      #
      # The keys that stopped EARLIER in the window and recovered get a bullet of their
      # own, because nothing else here would carry them: they read `fresh`, their
      # summary line is INFO and so is not in VictoriaLogs, and "no log lines" is not
      # evidence that nothing ran (tadasant/zimmer#584). The reader of this tool is an
      # agent with no route to /jobs, so this is the only surface on which it can ask
      # "has this sweep been running", rather than "is it running now".
      def cron_freshness_lines(report)
        cron = report[:cron_health] || {}
        status = cron[:status]
        return [] if status.nil?

        keys = cron[:keys] || []
        behind = keys.select { |r| %i[stale overdue].include?(r[:state]) }
        recovered = keys.select { |r| r[:state] == :fresh && r[:stopped_in_window] }

        [
          "- **Cron freshness:** #{status.message}",
          *behind.map { |r| "  - `#{r[:key]}` (#{r[:state]}): #{r[:reason]}" },
          *recovered.map { |r| recovered_key_line(r) }
        ]
      end

      # Whether each webhook source is delivering, and whether the poller has had to fire for it —
      # the reading that says if `webhook_with_poll_fallback` is proving itself. One line per source
      # whose webhook is switched on; one line in all when none is, which is the default.
      def inbound_event_lines(report)
        inbound = report[:inbound_event_health] || {}
        status = inbound[:status]
        return [] if status.nil?

        enabled = (inbound[:sources] || []).select { |s| s[:webhook_enabled] }

        [
          "- **Webhook ingest:** #{status.message}",
          *enabled.map { |s| inbound_source_line(s) }
        ]
      end

      def inbound_source_line(source)
        last = source[:last_delivery_at]&.utc&.strftime("%Y-%m-%d %H:%M UTC") || "none in the last 7 days"

        "  - `#{source[:name]}` (#{source[:mode]}): last delivery #{last}; last 24h: " \
          "#{source[:deliveries_in_window]} deliveries, #{source[:webhook_claims_in_window]} fires via webhook, " \
          "#{source[:poll_claims_in_window]} via poll"
      end

      def recovered_key_line(reading)
        window = CronFreshness::HISTORY_WINDOW.inspect
        silence = HealthMonitorService.format_wait(reading[:longest_gap_seconds])
        resumed = reading[:gap_ended_at]&.utc&.strftime("%Y-%m-%d %H:%M UTC")

        "  - `#{reading[:key]}` (enqueuing now, but stopped earlier): #{reading[:ticks_in_window]} tick(s) " \
          "in the last #{window}, longest silence #{silence}, resumed #{resumed}"
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

      # Where secrets resolve from, and — the reason this is here — whether the
      # Parameter Store namespace rename has finished.
      #
      # The rename from `/zimmer/{env}/mcp/static/` to
      # `/zimmer/{env}/secrets/static/` cannot happen in place, so the resolver
      # reads BOTH namespaces across the move and a later PR drops the pre-rename
      # read path. Nothing raises either way: the resolution chain's contract is
      # that a miss is not an error, so dropping that read path while data still
      # sits at the old path turns every affected `${VAR}` into "Missing
      # configuration" in silence. The precondition for that PR is "nothing
      # remains in the pre-rename namespace". The Connectors page store banner
      # answers that for a human; an agent session cannot read a web page, so
      # without this section the session assigned the follow-up has to park in
      # `needs_input` asking a human to read a banner back to it, or proceed blind.
      #
      # NAMES, NEVER VALUES. This response is read by other agent sessions, so a
      # value folded in here would be secret material handed to every caller.
      # `legacy_variables` is name-only for exactly that reason; nothing below
      # calls `get`, `has?` or anything else that can return a value.
      #
      # Reporting, not resolving, so it reads `refresh: false` — what the process
      # already holds, never a fresh round trip to Google. A health report is the
      # wrong place to inherit a store's latency, and the caller most likely to
      # ask is the one triaging a store that is not answering.
      #
      # Always present, in both directions — an explicit "none" rather than an
      # absent section, so a caller asking "is the migration done?" can tell "yes"
      # from "this report doesn't say". A namespace nobody has read says so rather
      # than reading as finished.
      def secret_store_lines
        store = SecretProviders.chain.providers.find { |p| p.is_a?(SecretProviders::ParameterStoreProvider) }
        return [ "", "### Secret Store", *no_store_lines ] if store.nil?

        [
          "",
          "### Secret Store",
          "- **Store:** #{SecretsLocation.parameter_store_name} — project " \
            "`#{store.project_id}` (#{store.location})",
          "- **Canonical namespace:** `#{store.namespace}`",
          *namespace_migration_lines(store)
        ]
      rescue StandardError => e
        # The class only, unless it is a StoreError. Other error messages can
        # embed a window of a response body, and on this path a body is a
        # rendered secret — the reasoning ParameterStore::SnapshotCache spells out.
        summary = e.is_a?(ParameterStore::StoreError) ? "#{e.class}: #{e.message}" : e.class.to_s
        Rails.logger.warn("[GetSystemHealth] Could not read the secret store (#{summary})")
        [ "", "### Secret Store", "- **Secret store:** unavailable (#{e.class})" ]
      end

      def no_store_lines
        reason = SecretProviders.parameter_store_configuration.reason.presence || "no resolver credential"

        [
          "- **Store:** #{SecretsLocation.credentials_store_name} — the Google Parameter Store is not " \
            "configured (#{reason}), so there is no namespace migration to report."
        ]
      end

      # @param store [SecretProviders::ParameterStoreProvider]
      def namespace_migration_lines(store)
        if store.legacy_namespaces.empty?
          return [ "- **Pre-rename namespaces still read:** none — the namespace migration is complete." ]
        end

        [
          "- **Pre-rename namespaces still read:** #{store.legacy_namespaces.map { |ns| "`#{ns}`" }.join(", ")}",
          legacy_variable_line(store.legacy_variables(refresh: false))
        ]
      end

      # nil is not an empty list. A namespace the process has no snapshot of has
      # not been read, and reporting it as empty is the single wrong answer here —
      # it would tell the follow-up PR to go ahead.
      #
      # @param remaining [Array<String>, nil]
      def legacy_variable_line(remaining)
        if remaining.nil?
          "- **Names still answering from a pre-rename namespace:** unknown — this process holds no " \
            "snapshot of the store yet."
        elsif remaining.empty?
          "- **Names still answering from a pre-rename namespace:** none — that read path can be dropped."
        else
          "- **Names still answering from a pre-rename namespace (#{remaining.size}):** " \
            "#{remaining.join(", ")} (names only; run `bin/rails parameter_store:migrate_namespace` " \
            "with the writer credential to plan the move)"
        end
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
