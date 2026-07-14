# frozen_string_literal: true

# Observability diagnostics.
#
# Zimmer's telemetry initializers are deliberately hard no-ops when their env vars
# are missing (config/initializers/otel_logs_exporter.rb, config/initializers/sentry.rb),
# so dev/test/CI never touch the network. The cost of that design is that a
# MISCONFIGURED deployment looks exactly like a healthy one from the inside: no
# errors, no warnings, just no data arriving in Grafana. These tasks exist to make
# that state observable from inside the container.
#
#   bin/rails obs:status   # what is this instance shipping, and where to?
#   bin/rails obs:smoke    # push a uniquely-tagged record end-to-end and report the ingest status code
#
# Neither task prints a bearer token or a DSN key, so their output is safe to paste
# into a deploy log, an issue, or a PR.

namespace :obs do
  # A Sentry/GlitchTip DSN embeds a (public, but still not worth pasting around)
  # key: https://<key>@host/<project_id>. Reduce it to the two parts that actually
  # answer "which GlitchTip project do my errors land in?".
  def redacted_dsn(dsn)
    uri = URI.parse(dsn)
    "#{uri.host}#{uri.path}"
  rescue URI::InvalidURIError
    "(unparseable)"
  end

  desc "Report which observability signals this instance is actually shipping (no secrets printed)."
  task status: :environment do
    exporter = OtelLogsExporter.instance
    dsn = ENV["SENTRY_DSN_BACKEND"].to_s

    puts "Zimmer observability status"
    puts "  deployment.environment : #{Rails.env}"
    puts "  service.name           : #{ENV.fetch("OTEL_SERVICE_NAME", "zimmer")}"
    puts ""

    if exporter
      d = exporter.describe
      puts "  [ON ] OTLP logs  -> #{d[:endpoint]}"
      puts "        export thread running=#{d[:running]} pending=#{d[:pending]}"
    else
      puts "  [OFF] OTLP logs  -- OTEL_LOGS_EXPORTER_ENDPOINT=#{ENV["OTEL_LOGS_EXPORTER_ENDPOINT"].present? ? "set" : "UNSET"}" \
           " OTEL_LOGS_EXPORTER_BEARER_TOKEN=#{ENV["OTEL_LOGS_EXPORTER_BEARER_TOKEN"].present? ? "set" : "UNSET"}"
      puts "        Both must be non-empty; either one missing is a silent no-op."
    end

    # `Sentry.initialized?` is NOT the same question as "do errors ship". The SDK
    # initializes whenever the DSN is present, in any environment; the environment
    # allowlist in config/initializers/sentry.rb then drops events at the client
    # outside production/staging. Reporting ON off `initialized?` would tell an
    # agent-session shell — which inherits the production DSN — that its test-env
    # errors are being shipped, when they are (deliberately) being dropped.
    if Sentry.initialized? && Sentry.configuration.sending_allowed?
      puts "  [ON ] Errors     -> #{redacted_dsn(dsn)} (environment=#{Rails.env})"
    elsif Sentry.initialized?
      puts "  [OFF] Errors     -- SENTRY_DSN_BACKEND set, but Rails.env=#{Rails.env} is not in" \
           " enabled_environments (#{Sentry.configuration.enabled_environments.join(", ")})."
      puts "        Events are dropped at the client. This is the guard that keeps a"
      puts "        non-production process from paging the production alert channel."
    else
      puts "  [OFF] Errors     -- SENTRY_DSN_BACKEND=#{dsn.present? ? "set but Sentry not initialized" : "UNSET"}"
    end

    # Zimmer ships neither. Stated explicitly because "no metrics in Grafana" is
    # otherwise indistinguishable from a broken metrics pipeline, and someone will
    # go looking for the bug that isn't there.
    puts "  [--] Metrics     -- not shipped by Zimmer (no exporter; the obs stack's"
    puts "                      VictoriaMetrics only holds host/node metrics for this box)"
    puts "  [--] Traces      -- not shipped by Zimmer (Sentry traces_sample_rate=0.0,"
    puts "                      no OTLP trace exporter)"
  end

  desc "Emit a uniquely-tagged record through every live telemetry path and report whether the collector accepted it."
  task smoke: :environment do
    marker = "obs-smoke-#{SecureRandom.hex(6)}"
    glitchtip_probed = false
    exporter = OtelLogsExporter.instance

    puts "marker: #{marker}"
    puts "env   : #{Rails.env}"
    puts ""

    # 1. Synchronous ingest probe. This is the whole point of the task: it asks the
    #    collector a direct question and gets a status code back. The async export
    #    thread can only ever warn to stderr, which means a bad bearer token (401),
    #    a bad path (404), and an unreachable host are indistinguishable from
    #    "everything is fine, there just were no errors to ship".
    if exporter
      puts "[1/3] OTLP ingest probe -> #{exporter.describe[:endpoint]}"
      result = exporter.deliver([ {
        timestamp: Time.now.to_f,
        severity: "ERROR",
        scope: OtelLogsExporter::LOGGER_SCOPE,
        body: "[obs:smoke] synchronous ingest probe #{marker}",
        attributes: { "obs_smoke_marker" => marker, "probe" => "synchronous" }
      } ])

      if result.ok
        puts "      ✅ accepted (#{result})"
      else
        puts "      ❌ rejected (#{result})"
        puts "         401 -> OTEL_LOGS_EXPORTER_BEARER_TOKEN does not match the obs Caddy gate's token."
        puts "         404 -> OTEL_LOGS_EXPORTER_ENDPOINT path is wrong (want .../otel/v1/logs, no trailing slash)."
        puts "         timeout/DNS -> the collector is unreachable from this host."
      end
    else
      puts "[1/3] OTLP ingest probe -- SKIPPED: exporter disabled (run `bin/rails obs:status`)."
    end

    # 2. The real path, exercised for real: a Rails.logger.error goes through the
    #    broadcast appender -> bounded queue -> export thread. A probe that passes
    #    while this produces nothing in VictoriaLogs would mean the appender, not
    #    the network, is broken.
    puts "[2/3] Live logger path (Rails.logger.error -> broadcast appender -> export thread)"
    Rails.logger.error("[obs:smoke] live logger path #{marker}")
    if exporter&.describe&.fetch(:running)
      # Wait for the export thread to drain the queue rather than racing
      # `at_exit { shutdown }`, which closes the queue and silently drops whatever is
      # still in it. pending==0 means the record was POPPED, not that the POST has
      # returned, so allow a brief settle for the in-flight request. Bounded on both
      # sides: a wedged exporter delays the task, it does not hang it.
      deadline = Time.now + 10
      sleep 0.1 while exporter.pending.positive? && Time.now < deadline
      sleep 1
      puts "      handed to the export thread (pending=#{exporter.pending})"
    elsif exporter
      puts "      export thread is NOT running -- the record was queued but nothing will ship it."
    else
      puts "      exporter disabled; the line was logged to stdout only."
    end

    # 3. GlitchTip. Sentry.close flushes the SDK's background worker; it also
    #    permanently disables the client, which is correct for a one-shot rake
    #    process and is why this task must not be invoked in-process.
    if Sentry.initialized? && Sentry.configuration.sending_allowed?
      puts "[3/3] GlitchTip event"
      Sentry.capture_message("[obs:smoke] #{marker}", level: :error)
      Sentry.close
      puts "      captured + flushed"
      glitchtip_probed = true
    elsif Sentry.initialized?
      # Capturing here would print "captured + flushed" for an event the client
      # discards, and then send you looking for it in GlitchTip. Say so instead.
      puts "[3/3] GlitchTip event -- SKIPPED: Rails.env=#{Rails.env} is not in enabled_environments" \
           " (#{Sentry.configuration.enabled_environments.join(", ")});"
      puts "      the DSN is set, but events are dropped at the client. Nothing to smoke-test."
    else
      puts "[3/3] GlitchTip event -- SKIPPED: Sentry not initialized (SENTRY_DSN_BACKEND unset)."
    end

    puts ""
    puts "Now confirm the data landed. On the obs droplet:"
    puts "  curl -s http://127.0.0.1:9428/select/logsql/query --data-urlencode \\"
    puts "    'query={service.name=\"zimmer\"} deployment.environment:=#{Rails.env} \"#{marker}\"'"
    puts "Expect 2 records (the probe + the live logger line) if both steps above passed."
    if glitchtip_probed
      puts "In GlitchTip: search the zimmer-#{Rails.env} project's issues for #{marker}."
    end
  end
end
