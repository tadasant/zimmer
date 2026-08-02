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

  private

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
