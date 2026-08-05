class ApplicationController < ActionController::Base
  include ControllerDatabaseRetry

  # Handle 404 errors gracefully
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  # A tokenless (or stale-token) non-GET request is a client-side condition, not
  # broken server behavior. Rails' default :exception CSRF strategy raises
  # ActionController::InvalidAuthenticityToken, which DebugExceptions logs at ERROR
  # — and a single ERROR line trips the critical "Zimmer backend logging errors"
  # Grafana alert. The record that page carries is ~100% gem stack frames, so the
  # alert names no route, verb, IP, or client and cannot be triaged at all (#295).
  #
  # ErrorsController already set this precedent for the structurally identical
  # ActionController::RoutingError: don't suppress the signal, re-log it at INFO
  # with the fields triage actually needs.
  #
  # CSRF enforcement is unchanged. verify_authenticity_token still runs, still
  # raises, and the action still never executes; the request is still rejected with
  # the same 422 Rails would have returned. Only the log level and the information
  # content of the line change. Do NOT "simplify" this to skip_forgery_protection
  # or `protect_from_forgery with: :null_session` here — either would disable CSRF
  # enforcement for every descendant controller with no visible symptom.
  rescue_from ActionController::InvalidAuthenticityToken, with: :invalid_authenticity_token

  before_action :reconcile_queue_recovery_mode

  private

  # The web-process half of QueueRecoveryMode's TTL backstop.
  #
  # QueueRecoveryModeExpiryJob is the primary path, but it runs on the `agents`
  # queue and sixteen long-running sessions can occupy every thread on it — which
  # is exactly the incident recovery mode gets entered for. This path needs no
  # worker thread at all, so the two cover each other.
  #
  # Throttled to one check per RECOVERY_MODE_RECONCILE_INTERVAL per process so it is
  # not a query on every request, and swallowed entirely on failure: a backstop must
  # never be the reason a page 500s.
  #
  # The throttle is a process-local monotonic clock, deliberately NOT Rails.cache.
  # A cache-based guard would have been worse than none: production's
  # redis_cache_store wraps writes in a failsafe that RETURNS NIL rather than
  # raising when Redis is down, so a falsy return would have skipped the check —
  # switching this backstop off in exactly the degraded conditions it exists for.
  # A monotonic clock has no such dependency, and per-process is granular enough:
  # Zimmer runs one Puma process, and an extra check per process costs one indexed
  # read of a one-row table.
  #
  # `defer_alert` because AlertService posts to Slack inline and SlackService may
  # spend tens of seconds on an unreachable Slack. See QueueRecoveryModeAlertJob.
  RECOVERY_MODE_RECONCILE_INTERVAL = 30.seconds

  def reconcile_queue_recovery_mode
    return unless recovery_mode_reconcile_due?

    QueueRecoveryMode.expire_if_due!(defer_alert: true)
  rescue StandardError => e
    Rails.logger.error("[queue_recovery_mode] reconcile skipped: #{e.class}: #{e.message}")
    nil
  end

  def recovery_mode_reconcile_due?
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    last = self.class.recovery_mode_reconciled_at

    return false if last && (now - last) < RECOVERY_MODE_RECONCILE_INTERVAL.to_i

    self.class.recovery_mode_reconciled_at = now
    true
  end

  # Shared by every descendant controller: the throttle is about the process, not
  # about which controller happened to serve the request. Benign to race — the
  # worst outcome of two threads reading the same stale value is one extra query.
  class << self
    def recovery_mode_reconciled_at
      ApplicationController.instance_variable_get(:@recovery_mode_reconciled_at)
    end

    def recovery_mode_reconciled_at=(value)
      ApplicationController.instance_variable_set(:@recovery_mode_reconciled_at, value)
    end
  end

  def record_not_found
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end

  # Logged on one line, with everything needed to answer "was this a bot probe or a
  # real user's stale form?".
  #
  # Two fields carry the triage. `session_cookie` separates client populations:
  # present ⇒ a browser that has been here before (a stale form, an expired session,
  # an open tab across a deploy); absent ⇒ an unauthenticated probe. `reason` is the
  # exception message, and separates causes — Rails raises with either "Can't verify
  # CSRF token authenticity." (a missing or stale token, genuinely client-side) or
  # "HTTP Origin header (…) didn't match request.base_url (…)". The second is a
  # *server* fault: a proxy that stopped forwarding X-Forwarded-Proto or Host breaks
  # every write for every real user, which is what #19 was. Without the message the
  # two are one indistinguishable line, and the second would be silently downgraded.
  def invalid_authenticity_token(exception)
    Rails.logger.info(
      "CSRF verification failed 422: #{request.request_method} #{request.path} " \
      "ip=#{request.remote_ip} " \
      "session_cookie=#{session_cookie_present? ? "present" : "absent"} " \
      "user_agent=#{request.user_agent.to_s.inspect} " \
      "reason=#{exception.message.to_s.inspect}"
    )

    if request.format.json?
      render json: {
        error: "Unprocessable Entity",
        message: "CSRF token verification failed. Reload the page and try again."
      }, status: :unprocessable_entity
    else
      render plain: "The change you wanted was rejected: CSRF token verification failed. " \
        "Reload the page and try again.", status: :unprocessable_entity
    end
  end

  # Whether the *request* arrived carrying the session cookie — not whether a
  # session exists. Reading `session` would lazily mint an empty one and make every
  # request look session-present. The `present?` guard covers a deployment with no
  # session store mounted, where every request is legitimately session-absent.
  def session_cookie_present?
    key = Rails.application.config.session_options[:key]

    key.present? && request.cookies.key?(key)
  end
end
