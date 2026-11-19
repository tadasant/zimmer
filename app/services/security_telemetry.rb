# frozen_string_literal: true

# Security-relevant counts for the monitoring plane: who is failing to
# authenticate, how the machine surfaces are answering, and what was created.
#
# Before this existed Zimmer emitted no authentication signal at all. Most
# refusals log at INFO, which never leaves the container, and the WARN ones are
# per-record lines with an IP in them, not a rate. So "someone is guessing API
# keys" or "something is minting sessions a thousand at a time" were visible only
# indirectly, as connection counts and job throughput. This class is the rate.
#
# == Shape
#
# Every count is over the same trailing WINDOW, matching the windowed counts
# the rest of the health report carries (`processing_rate_per_hour`,
# `deliveries_in_window`). Recorded counts live in Rails.cache (Redis in
# production) as one counter per label set per BUCKET; a report sums the
# buckets that make up the window in one `read_multi`. The current bucket is
# included, so a count rises the moment an event is recorded — the window is the
# current bucket plus the eleven before it, so 55 to 60 minutes of history.
#
# == Labels are closed sets
#
# Every label value is drawn from a constant in this file. A reason or status
# nobody listed is counted as `other`, so a caller can never mint a new series,
# and nothing derived from the request — an IP, a token, a user, a path — can
# reach a key or a report. That is the whole privacy story: there is nowhere for
# PII or secret material to go.
#
# Every label set is reported, zeros included, so a series exists before its
# first event and an alert rule never has to tell "absent" from "zero".
#
# == Failure
#
# Recording never raises and never slows a refusal down: a cache error is
# swallowed (RedisCacheStore's failsafe already logs it at ERROR), and the
# test env's :null_store records nothing. A count that could not be recorded is
# lost, which undercounts; it never blocks or changes an auth decision. This
# class only observes.
module SecurityTelemetry
  WINDOW = 1.hour
  BUCKET = 5.minutes
  BUCKETS = (WINDOW / BUCKET).to_i
  # Long enough that every bucket in the window is still readable.
  TTL = WINDOW + BUCKET * 2
  KEY_PREFIX = "security_telemetry"
  OTHER = "other"

  # kind => the reasons it may carry. A reason not listed is recorded as `other`.
  AUTH_FAILURE_REASONS = {
    # The Google sign-in callback. `provider_error` is Google itself saying no
    # (including a person pressing Cancel); `flow_mismatch` is a callback whose
    # state does not match a sign-in this browser started.
    "web_sign_in" => %w[provider_error flow_mismatch rejected exchange_failed],
    # The TOTP step after Google. A wrong code is the brute-forceable credential.
    "web_second_factor" => %w[wrong_code locked enrollment_wrong_code],
    # Zimmer API keys, on /api and /mcp. `missing` includes an MCP client's
    # first, credential-less request, which is how OAuth discovery starts.
    "api_key" => %w[missing unknown revoked retired wrong_grant],
    # OAuth bearer tokens on /mcp and the iOS app's token on /api.
    "oauth_access_token" => %w[missing unknown revoked expired wrong_audience server_not_configured not_the_native_app],
    # POST /oauth/token: failed code exchanges and refreshes, by RFC 6749 error code.
    "oauth_token" => %w[invalid_grant invalid_client invalid_request unsupported_grant_type invalid_target],
    # GET/POST /oauth/authorize refused for the person, not the request.
    "oauth_authorize" => %w[not_signed_in domain_refused],
    # A plugin's API key that is valid but does not name an enabled plugin.
    "external_app" => %w[no_external_app disabled],
    # The GPT-Live delegation bearer on /live/delegation_mcp.
    "live_delegation_token" => %w[invalid],
    # The per-session token embedded in an elicitation URL.
    "elicitation_token" => %w[invalid],
    # Signed inbound webhooks, one kind per source.
    "webhook_github" => %w[bad_signature],
    "webhook_slack" => %w[bad_signature],
    "webhook_mcp_events" => %w[unknown_subscription bad_signature]
  }.transform_values { |reasons| (reasons + [ OTHER ]).freeze }.freeze

  AUTH_FAILURE_KINDS = AUTH_FAILURE_REASONS.keys.freeze

  # Which surface a request was for, by path prefix. Prefix rather than
  # controller so an unrouted probe (`/api/v1/admin`, answered 404 by
  # ErrorsController) still lands on the surface it was aimed at.
  SURFACES = %w[api mcp oauth webhooks web].freeze

  STATUS_CLASSES = %w[2xx 3xx 4xx 5xx].freeze

  # The 4xx codes worth telling apart when someone is probing.
  CLIENT_ERROR_STATUSES = %w[400 401 403 404 422 429].freeze
  CLIENT_ERROR_LABELS = (CLIENT_ERROR_STATUSES + [ OTHER ]).freeze

  module_function

  # @param kind [String, Symbol] one of AUTH_FAILURE_KINDS
  # @param reason [String, Symbol, nil] one of that kind's reasons; anything else is `other`
  def record_auth_failure(kind, reason)
    kind = kind.to_s
    reasons = AUTH_FAILURE_REASONS[kind]
    if reasons.nil?
      # A bug at the call site, never an attacker's input. Loud where tests run;
      # in production it must not turn a refusal into a 500.
      raise ArgumentError, "unknown auth failure kind #{kind.inspect}" if Rails.env.local?

      Rails.logger.error("[SecurityTelemetry] unknown auth failure kind #{kind.inspect}")
      return nil
    end

    reason = reason.to_s
    reason = OTHER unless reasons.include?(reason)
    increment("auth_failure", kind, reason)
  end

  # @param path [String] the request path (a query string is ignored)
  # @param status [Integer, nil] the response status
  def record_response(path, status)
    status = status.to_i
    return if status < 200 || status > 599

    surface = surface_for(path)
    increment("response", surface, "#{status / 100}xx")
    return unless status / 100 == 4

    code = status.to_s
    increment("client_error", surface, CLIENT_ERROR_STATUSES.include?(code) ? code : OTHER)
  end

  def surface_for(path)
    path = path.to_s
    if path.start_with?("/api/") || path == "/api"
      "api"
    elsif path.match?(%r{\A/mcp(?:[/?]|\z)}) || path.start_with?("/live/delegation_mcp")
      "mcp"
    elsif path.match?(%r{\A/oauth(?:[/?]|\z)}) || path.start_with?("/.well-known/oauth-")
      "oauth"
    elsif path.start_with?("/webhooks/")
      "webhooks"
    else
      "web"
    end
  end

  # The recorded counts over WINDOW, every label set present.
  #
  # @return [Hash]
  def report(now: Time.current)
    series = []
    AUTH_FAILURE_REASONS.each { |kind, reasons| reasons.each { |reason| series << [ "auth_failure", kind, reason ] } }
    SURFACES.each do |surface|
      STATUS_CLASSES.each { |klass| series << [ "response", surface, klass ] }
      CLIENT_ERROR_LABELS.each { |code| series << [ "client_error", surface, code ] }
    end

    totals = sum_window(series, now)

    by_reason = AUTH_FAILURE_REASONS.to_h do |kind, reasons|
      [ kind, reasons.to_h { |reason| [ reason, totals[[ "auth_failure", kind, reason ]] ] } ]
    end

    {
      window_seconds: WINDOW.to_i,
      auth_failures_by_kind: by_reason.transform_values { |counts| counts.values.sum },
      auth_failures_by_kind_and_reason: by_reason,
      responses_by_surface_and_status_class: SURFACES.to_h do |surface|
        [ surface, STATUS_CLASSES.to_h { |klass| [ klass, totals[[ "response", surface, klass ]] ] } ]
      end,
      client_errors_by_surface_and_status: SURFACES.to_h do |surface|
        [ surface, CLIENT_ERROR_LABELS.to_h { |code| [ code, totals[[ "client_error", surface, code ]] ] } ]
      end
    }
  end

  def increment(*labels)
    Rails.cache.increment(key(labels, bucket_for(Time.current)), 1, expires_in: TTL)
  rescue StandardError => e
    Rails.logger.error("[SecurityTelemetry] could not record #{labels.join(':')}: #{e.class}")
    nil
  end

  # @return [Hash{Array => Integer}] series => count over the window
  def sum_window(series, now)
    current = bucket_for(now)
    buckets = (0...BUCKETS).map { |offset| current - offset }
    keys = series.flat_map { |labels| buckets.map { |bucket| key(labels, bucket) } }
    values = Rails.cache.read_multi(*keys, raw: true)

    series.to_h do |labels|
      [ labels, buckets.sum { |bucket| values[key(labels, bucket)].to_i } ]
    end
  end

  def bucket_for(time)
    time.to_i / BUCKET.to_i
  end

  def key(labels, bucket)
    "#{KEY_PREFIX}:#{labels.join(':')}:#{bucket}"
  end
end
