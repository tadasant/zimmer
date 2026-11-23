# frozen_string_literal: true

# Security-relevant counts for the monitoring plane: who is failing to
# authenticate, how many people are signing in, how the machine surfaces are
# answering, and what was created.
#
# Most refusals log at INFO, which never leaves the container, and the WARN ones
# are per-record lines with an IP in them, not a rate. "Someone is guessing API
# keys" or "something is minting sessions a thousand at a time" needs a rate.
# This module is the rate.
#
# == Shape
#
# Every count is over the same trailing WINDOW, matching the windowed counts
# the rest of the health report carries (`processing_rate_per_hour`,
# `deliveries_in_window`). Recorded counts live in Rails.cache (Redis in
# production) as one counter per label set per BUCKET; a report sums the
# buckets that make up the window in one `read_multi`. The current bucket is
# included, so the window is the current bucket plus the eleven before it: 55 to
# 60 minutes of history.
#
# == Off the request path
#
# Recording never touches Redis. It adds one to a process-local Concurrent::Map
# keyed by the counter it belongs to (labels and bucket fixed at record time),
# and a background TimerTask in each process flushes the map with one INCRBY
# per counter every FLUSH_INTERVAL. So a slow or unreachable Redis costs the
# flusher thread, never a request: the response subscriber runs on every
# controller response, and a synchronous round trip there would have put
# Redis's connect and pool timeouts in front of every page, /api and /mcp call.
#
# The cost is that a count reaches the report up to FLUSH_INTERVAL late, and a
# process that exits loses whatever it had not flushed. A report flushes its own
# process first, so a reader in the web process sees that process's counts at
# once.
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
# Recording never raises and never waits on Redis. A flush that fails is
# logged and its counts dropped (RedisCacheStore's failsafe also logs the error),
# and the test env's :null_store keeps nothing. A count that could not be stored
# is lost, which undercounts; it never blocks or changes an auth decision. This
# module only observes.
module SecurityTelemetry
  WINDOW = 1.hour
  BUCKET = 5.minutes
  BUCKETS = (WINDOW / BUCKET).to_i
  # Long enough that every bucket in the window is still readable.
  TTL = WINDOW + BUCKET * 2
  KEY_PREFIX = "security_telemetry"
  FLUSH_INTERVAL = 10 # seconds
  OTHER = "other"

  # kind => the reasons it may carry. A reason not listed is recorded as `other`.
  AUTH_FAILURE_REASONS = {
    # The Google sign-in callback. `provider_error` is Google itself saying no
    # (including a person pressing Cancel); `flow_mismatch` is a callback whose
    # state does not match a sign-in this browser started.
    # A failed token exchange is Google, the network, or this deployment's own
    # client credential failing, not the caller, so it is not counted.
    "web_sign_in" => %w[provider_error flow_mismatch rejected],
    # The TOTP step after Google. A wrong code is the brute-forceable credential.
    "web_second_factor" => %w[wrong_code locked enrollment_wrong_code],
    # A WebSocket refused by the web login wall, for any reason. Not a guess
    # count: `no_cookie` is any signed-out browser, and a page that keeps
    # retrying its subscription is counted each time. The last five log at
    # ERROR (see ApplicationCable::Connection).
    "web_cable" => %w[
      no_cookie expired signed_out_everywhere second_factor_missing
      unreadable_cookie identity_missing domain_not_allowed misconfigured configuration_unavailable
    ],
    # Zimmer API keys, on /api and /mcp. `missing` includes an MCP client's
    # first, credential-less request, which is how OAuth discovery starts.
    "api_key" => %w[missing unknown revoked retired wrong_grant],
    # OAuth bearer tokens on /mcp and the iOS app's token on /api.
    "oauth_access_token" => %w[missing unknown revoked expired wrong_audience server_not_configured not_the_native_app],
    # POST /oauth/token: failed code exchanges and refreshes, by RFC 6749 error
    # code. `invalid_client` includes a client metadata document Zimmer could not
    # fetch, which is the client's host failing rather than a guess.
    "oauth_token" => %w[invalid_grant invalid_client invalid_request unsupported_grant_type invalid_target],
    # GET/POST /oauth/authorize refused for the person. A malformed request (an
    # unknown client_id, a bad redirect_uri) is not counted here; it shows as an
    # `oauth` 4xx in the response counts.
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

  # How far a web sign-in got. A signed-out tab polling or retrying its
  # WebSocket, and the daily re-issue of the sign-in cookie, move neither: it
  # takes submitting the login form. `started` is a browser sent to Google; `completed` is
  # one that passed Google, and the second factor where required, and was sent
  # the sign-in cookie. Whether the browser kept the cookie is not in here.
  WEB_SIGN_IN_STAGES = %w[started completed].freeze

  # Which surface a request was for, by path prefix. Prefix rather than
  # controller so an unrouted probe (`/api/v1/admin`, answered 404 by
  # ErrorsController) still lands on the surface it was aimed at.
  SURFACES = %w[api mcp oauth webhooks web].freeze

  STATUS_CLASSES = %w[2xx 3xx 4xx 5xx].freeze

  # The 4xx codes worth telling apart when someone is probing.
  CLIENT_ERROR_STATUSES = %w[400 401 403 404 422 429].freeze
  CLIENT_ERROR_LABELS = (CLIENT_ERROR_STATUSES + [ OTHER ]).freeze

  FLUSHER_LOCK = Mutex.new

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

  # @param stage [String, Symbol] one of WEB_SIGN_IN_STAGES
  def record_web_sign_in(stage)
    stage = stage.to_s
    unless WEB_SIGN_IN_STAGES.include?(stage)
      # As above: loud where tests run, and never a failed sign-in in production.
      raise ArgumentError, "unknown web sign-in stage #{stage.inspect}" if Rails.env.local?

      Rails.logger.error("[SecurityTelemetry] unknown web sign-in stage #{stage.inspect}")
      return nil
    end

    increment("web_sign_in", stage)
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
    flush!
    series = []
    AUTH_FAILURE_REASONS.each { |kind, reasons| reasons.each { |reason| series << [ "auth_failure", kind, reason ] } }
    WEB_SIGN_IN_STAGES.each { |stage| series << [ "web_sign_in", stage ] }
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
      web_sign_ins_by_stage: WEB_SIGN_IN_STAGES.to_h { |stage| [ stage, totals[[ "web_sign_in", stage ]] ] },
      responses_by_surface_and_status_class: SURFACES.to_h do |surface|
        [ surface, STATUS_CLASSES.to_h { |klass| [ klass, totals[[ "response", surface, klass ]] ] } ]
      end,
      client_errors_by_surface_and_status: SURFACES.to_h do |surface|
        [ surface, CLIENT_ERROR_LABELS.to_h { |code| [ code, totals[[ "client_error", surface, code ]] ] } ]
      end
    }
  end

  # Adds one to this process's pending count. Never touches Redis.
  def increment(*labels)
    pending.compute(key(labels, bucket_for(Time.current))) { |count| (count || 0) + 1 }
    ensure_flusher
    nil
  rescue StandardError => e
    Rails.logger.error("[SecurityTelemetry] could not record #{labels.join(':')}: #{e.class}")
    nil
  end

  # Moves this process's pending counts into Rails.cache. `delete` hands each
  # count to exactly one flush, and a record racing it starts a fresh entry that
  # the next flush carries.
  def flush!
    pending.each_key do |key|
      count = pending.delete(key)
      Rails.cache.increment(key, count, expires_in: TTL) if count.to_i.positive?
    end
    nil
  rescue StandardError => e
    Rails.logger.error("[SecurityTelemetry] could not flush counts: #{e.class}")
    nil
  end

  # Drops this process's pending counts unflushed. For tests.
  def discard_pending!
    pending.clear
  end

  def pending
    @pending ||= Concurrent::Map.new
  end

  # One flusher per process, started on first use. Keyed on the pid because a
  # forked Puma worker inherits the parent's ivar but not its thread. Not in the
  # test env, where a report flushes on demand and a timer would flush one test's
  # counts into another's store.
  def ensure_flusher
    return if Rails.env.test?
    return if @flusher_pid == Process.pid

    FLUSHER_LOCK.synchronize do
      return if @flusher_pid == Process.pid

      @flusher = Concurrent::TimerTask.new(execution_interval: FLUSH_INTERVAL) { flush! }
      @flusher.execute
      @flusher_pid = Process.pid
    end
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
