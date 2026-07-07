# OTLP/HTTP logs exporter — ships Zimmer's ERROR signal to your obs stack.
# =========================================================================
# Zimmer's failures live in GoodJob background jobs and the
# session-lifecycle subsystem, not HTTP requests (the same rationale that
# shapes config/initializers/sentry.rb). This exporter ships those failures
# to an OTel Collector via OTLP/HTTP so Grafana can alert on
# them out of VictoriaLogs — the signal GlitchTip alone cannot provide
# (Grafana cannot query GlitchTip).
#
# Two record sources are wired in the after_initialize block below:
#   - `perform.active_job` terminal failures  → scope `rails.activejob`
#     (structured ERROR records with queryable job_class/queue/job_id).
#   - every WARN/ERROR/FATAL `Rails.logger` line → scope `rails.logger`
#     (the broad catch-all: StructuredLogger#error, Rails.logger.error from
#     services/jobs, and Rails' own unhandled-exception logs).
#
# Resource attributes on every batch (the fields a Grafana LogsQL alert
# selector matches on):
#   service.name = zimmer
#   deployment.environment = <Rails.env>   (production / staging)
#   severity_text ∈ {INFO, WARN, ERROR, FATAL}   (OTLP severityText)
#
# Wire format: minimal hand-rolled OTLP/HTTP JSON. We avoid the alpha-quality
# `opentelemetry-logs-sdk` gem and hit the documented OTLP/HTTP logs endpoint
# directly — no new gem dependencies (net/http + json are stdlib).
#
# Configuration (env vars; absence of either is a hard no-op, so dev/test/CI
# never attempt network I/O):
#   OTEL_LOGS_EXPORTER_ENDPOINT      e.g. https://obs.tadasant.com/otel/v1/logs
#   OTEL_LOGS_EXPORTER_BEARER_TOKEN  shared secret matching Caddy's bearer gate
#                                    (matches your obs ingest gateway's token)
#   OTEL_SERVICE_NAME                optional; defaults to "zimmer"
#
# Failure mode: if the exporter is wedged or the obs droplet is down, the
# background thread logs once and drops the batch. Job/log handling is never
# blocked — exports happen on a separate thread and the bounded queue caps
# memory at ~1 MB.

require "net/http"
require "json"
require "uri"

class OtelLogsExporter
  MAX_QUEUE_SIZE = 1_000
  BATCH_SIZE = 64

  # Job-failure records and the broadcast logger appender carry these
  # instrumentation-scope names so VictoriaLogs/Grafana can tell terminal
  # job failures apart from generic logger output. Each distinct scope
  # becomes its own `scopeLogs` entry in the OTLP envelope.
  ACTIVEJOB_SCOPE = "rails.activejob"
  LOGGER_SCOPE = "rails.logger"

  # Records that don't carry an explicit `:scope` group under this name.
  DEFAULT_SCOPE = LOGGER_SCOPE

  # Cap exported bodies so a stack-trace-laden error message can't blow up a
  # single OTLP record (and, transitively, the bounded export queue's memory).
  MAX_BODY_CHARS = 8_000

  def self.start!
    return @instance if defined?(@instance) && @instance

    endpoint = ENV["OTEL_LOGS_EXPORTER_ENDPOINT"]
    token = ENV["OTEL_LOGS_EXPORTER_BEARER_TOKEN"]
    return nil if endpoint.nil? || endpoint.empty? || token.nil? || token.empty?

    @instance = new(endpoint: endpoint, token: token)
    @instance.start
    @instance
  end

  def self.instance
    @instance if defined?(@instance)
  end

  # Shapes the structured ERROR record emitted when an ActiveJob/GoodJob run
  # raises an unhandled exception (the job is discarded, or has exhausted its
  # `retry_on` attempts and re-raised). Pure function with no I/O, so the
  # record shape is unit-testable without the background thread or network.
  # The `:scope` keys the record into the `rails.activejob` OTLP scope, and the
  # structured attributes give VictoriaLogs/Grafana queryable
  # job_class/queue/job_id fields the plain ActiveJob error log line lacks.
  def self.build_job_failure_record(job_class:, queue:, job_id:, executions:, exception_class:, exception_message:, timestamp: nil)
    message = exception_message.to_s
    message = "#{message[0, MAX_BODY_CHARS]}…" if message.length > MAX_BODY_CHARS
    {
      timestamp: timestamp,
      severity: "ERROR",
      scope: ACTIVEJOB_SCOPE,
      body: "Job #{job_class} failed: #{exception_class}: #{message}",
      attributes: {
        "job_class" => job_class,
        "queue" => queue,
        "job_id" => job_id,
        "executions" => executions,
        "exception_class" => exception_class,
        "exception_message" => message
      }
    }
  end

  def initialize(endpoint:, token:)
    @endpoint = URI.parse(endpoint)
    @token = token
    @queue = SizedQueue.new(MAX_QUEUE_SIZE)
    @stopped = false
    @service_name = ENV["OTEL_SERVICE_NAME"] || "zimmer"
    @env_name = ENV["RAILS_ENV"] || (defined?(Rails) ? Rails.env.to_s : "unknown")
  end

  def start
    @thread = Thread.new { run_loop }
    @thread.name = "otel-logs-exporter"
    at_exit { shutdown }
  end

  def enqueue(record)
    @queue.push(record, true)
  rescue ThreadError
    # Queue is full — drop. Better than blocking a job/log thread.
  end

  def shutdown
    @stopped = true
    @queue.close if @queue.respond_to?(:close)
  end

  private

  def run_loop
    until @stopped
      first = @queue.pop  # blocks; returns nil after queue.close
      break if first.nil?
      batch = [ first ]
      (BATCH_SIZE - 1).times do
        batch << @queue.pop(true)
      rescue ThreadError
        break
      end
      send_batch(batch)
    end
  rescue => e
    warn "[otel_logs_exporter] run_loop crashed: #{e.class}: #{e.message}"
  end

  def send_batch(records)
    body = build_envelope(records)
    http = Net::HTTP.new(@endpoint.host, @endpoint.port)
    http.use_ssl = (@endpoint.scheme == "https")
    http.open_timeout = 5
    http.read_timeout = 10
    request = Net::HTTP::Post.new(@endpoint.request_uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"
    request.body = body
    response = http.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      warn "[otel_logs_exporter] non-2xx from #{@endpoint}: #{response.code} #{response.body.to_s[0, 200]}"
    end
  rescue => e
    warn "[otel_logs_exporter] export failed: #{e.class}: #{e.message}"
  end

  def build_envelope(records)
    # Group records into OTLP `scopeLogs` entries by their instrumentation
    # scope so a single batch can carry job-failure records (`rails.activejob`)
    # and generic logger output (`rails.logger`) side by side. Records without
    # an explicit `:scope` default to DEFAULT_SCOPE.
    scope_logs = records.group_by { |r| (r[:scope] || DEFAULT_SCOPE).to_s }.map do |scope_name, scoped_records|
      {
        scope: { name: scope_name },
        logRecords: scoped_records.map { |r| log_record(r) }
      }
    end

    JSON.generate(
      resourceLogs: [ {
        resource: {
          attributes: [
            { key: "service.name", value: { stringValue: @service_name } },
            { key: "deployment.environment", value: { stringValue: @env_name } }
          ]
        },
        scopeLogs: scope_logs
      } ]
    )
  end

  def log_record(record)
    timestamp_ns = ((record[:timestamp] || Time.now.to_f) * 1_000_000_000).to_i
    severity = (record[:severity] || "INFO").to_s.upcase
    {
      timeUnixNano: timestamp_ns.to_s,
      observedTimeUnixNano: timestamp_ns.to_s,
      severityNumber: severity_number(severity),
      severityText: severity,
      body: { stringValue: scrub(record[:body].to_s) },
      attributes: build_attributes(record[:attributes] || {})
    }
  end

  # Coerce any string into valid UTF-8 before it reaches JSON.generate. Without
  # this, a single binary/invalid-UTF-8 byte sequence in an exception message or
  # logged body (common with ASCII-8BIT strings from IO/network libs) raises
  # JSON::GeneratorError on the export thread, dropping the ENTIRE batch — not
  # just the offending record. Exception messages and arbitrary Rails.logger
  # bodies flow through here, so the exposure is real. Replace, don't raise.
  def scrub(str)
    if str.encoding == Encoding::UTF_8 && str.valid_encoding?
      str
    else
      str.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
    end
  end

  SEVERITY_NUMBERS = {
    "TRACE" => 1, "DEBUG" => 5, "INFO" => 9, "WARN" => 13,
    "ERROR" => 17, "FATAL" => 21
  }.freeze

  def severity_number(level)
    SEVERITY_NUMBERS.fetch(level.to_s.upcase, 9)
  end

  def build_attributes(hash)
    hash.map do |k, v|
      next nil if v.nil?
      { key: k.to_s, value: serialize_value(v) }
    end.compact
  end

  def serialize_value(value)
    case value
    when Integer then { intValue: value.to_s }
    when Float then { doubleValue: value }
    when TrueClass, FalseClass then { boolValue: value }
    when Array, Hash then { stringValue: scrub(JSON.generate(value)) }
    else { stringValue: scrub(value.to_s) }
    end
  end
end

# A secondary Rails.logger sink that ships WARN/ERROR/FATAL records to the
# OTLP exporter, so generic `Rails.logger.warn`/`.error` calls from app, job,
# and service code reach VictoriaLogs. This is the broad catch-all: it carries
# StructuredLogger#error output (Zimmer's primary deliberate error surface), any
# `Rails.logger.error` from the session-lifecycle subsystem, and Rails' own
# unhandled-exception logs.
#
# Broadcast onto Rails.logger via `broadcast_to` (Rails 8 BroadcastLogger), so
# it runs ALONGSIDE the normal stdout logger rather than replacing it. INFO and
# DEBUG are dropped here (level = WARN) to keep export volume and the bounded
# queue sane.
#
# Records carry scope `rails.logger` to distinguish them from the structured
# `rails.activejob` job-failure records.
class OtelLogAppender < ::Logger
  LEVEL_TEXT = {
    ::Logger::WARN => "WARN",
    ::Logger::ERROR => "ERROR",
    ::Logger::FATAL => "FATAL"
  }.freeze

  def initialize(exporter)
    # No log device: this sink never writes to a file/stdout itself; `add` is
    # fully overridden to forward to the exporter instead.
    super(nil)
    @exporter = exporter
    self.level = ::Logger::WARN
  end

  def add(severity, message = nil, progname = nil)
    severity ||= ::Logger::UNKNOWN
    return true if severity < level

    severity_text = LEVEL_TEXT[severity] || "ERROR"
    body = message
    body = yield if body.nil? && block_given?
    body = progname if body.nil?
    body = body.to_s
    body = "#{body[0, OtelLogsExporter::MAX_BODY_CHARS]}…" if body.length > OtelLogsExporter::MAX_BODY_CHARS

    @exporter.enqueue(
      timestamp: Time.now.to_f,
      severity: severity_text,
      scope: OtelLogsExporter::LOGGER_SCOPE,
      body: body,
      attributes: {}
    )
    true
  rescue => e
    # Never let a logging failure raise into application code. Route through
    # Kernel.warn explicitly — NOT Rails.logger, and NOT a bare `warn` (which
    # resolves to ::Logger#warn on this subclass and would re-enter `add`,
    # recursing infinitely). standardrb's StderrPuts cop rewrites
    # `$stderr.puts` into a bare `warn`, so the fully-qualified Kernel.warn is
    # required to keep the recursion-safe behavior through linting.
    Kernel.warn "[otel_logs_exporter] log appender error: #{e.class}: #{e.message}"
    true
  end
end

# Boot the exporter and wire the record sources. Only active when both env
# vars are set, so dev/test/CI never attempt network I/O.
Rails.application.config.after_initialize do
  exporter = OtelLogsExporter.start!
  next unless exporter

  # Job-failure instrumentation (PRIMARY structured signal).
  # `perform.active_job` carries `:exception_object` only when the job's
  # `perform` raised AND the exception propagated out of the executor — i.e.
  # an unhandled error that GoodJob discards, or the final re-raise after
  # `retry_on` attempts are exhausted. Intermediate `retry_on` attempts and
  # `discard_on`-handled errors swallow the exception before this point and
  # carry no `:exception_object`, so they are correctly NOT emitted here. This
  # mirrors the logging philosophy: only the terminal, non-self-resolving
  # failure is shipped as ERROR.
  ActiveSupport::Notifications.subscribe("perform.active_job") do |*args|
    event = ActiveSupport::Notifications::Event.new(*args)
    payload = event.payload
    exception_object = payload[:exception_object]
    exception_pair = payload[:exception]
    next unless exception_object || exception_pair

    job = payload[:job]
    exception_class = exception_object&.class&.name || exception_pair&.first
    exception_message = exception_object&.message || exception_pair&.last

    exporter.enqueue(
      OtelLogsExporter.build_job_failure_record(
        job_class: job&.class&.name,
        queue: job&.queue_name,
        job_id: job&.job_id,
        executions: job&.executions,
        exception_class: exception_class,
        exception_message: exception_message,
        timestamp: event.time.to_f
      )
    )
  rescue => e
    warn "[otel_logs_exporter] activejob subscriber error: #{e.class}: #{e.message}"
  end

  # Broad catch-all: ship every WARN/ERROR/FATAL Rails.logger record to the
  # OTLP path (scope `rails.logger`). Broadcast alongside the existing logger
  # so stdout logging is unaffected.
  if Rails.logger.respond_to?(:broadcast_to)
    Rails.logger.broadcast_to(OtelLogAppender.new(exporter))
  else
    warn "[otel_logs_exporter] Rails.logger does not support broadcast_to; logger-level export disabled"
  end
end
