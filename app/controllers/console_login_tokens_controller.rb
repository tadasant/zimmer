# frozen_string_literal: true

# Mint and revoke console login tokens (tadasant/zimmer#220): the standing-credential
# half of the agent-login primitive.
#
# Both actions sit behind the operator credential (OperatorHttpBasicAuth,
# `SUPERVISOR_PASSWORD`) and take JSON, so the caller is `curl -u` from a CI job
# whose secret never leaves it. That credential, and not an API key, for the same
# reason `/settings/api_keys` gives: every agent session holds an API key, and the
# operator password is the one credential `CliSpawnEnv` keeps out of them. A surface
# where the fleet's shared key could mint console sessions would make the credential
# self-issuing. There is no MCP tool and no `/api/v1` route for this, on purpose.
#
# The token is in the `create` response and nowhere else. `Cache-Control: no-store`
# keeps it out of any HTTP cache on the way; the table holds its digest.
#
# `revoke` is what an actor calls on a token it minted and could not exchange, before
# it mints again — a failed exchange on an unused token means someone else saw it, or
# the flow is broken, and either way the id should be dead before the next attempt.
# It is idempotent, and a no-op on a consumed token: the exchanged session has its
# own expiry, and revoking the token that produced it changes nothing about it.
#
# Everything is closed unless `CONSOLE_LOGIN_ENABLED` is `true` — see ConsoleLoginGate,
# which runs before the operator check so a closed deployment never challenges.
class ConsoleLoginTokensController < ActionController::API
  include ControllerDatabaseRetry
  include ActionController::HttpAuthentication::Basic::ControllerMethods
  include ConsoleLoginGate
  include OperatorHttpBasicAuth

  before_action :authenticate_operator

  rescue_from ActiveRecord::RecordNotFound do
    render_console_login_error("Not Found", "No console login token with that id", status: :not_found)
  end

  # POST /console_login_tokens
  #
  # Body: `principal` (required — who this login is for, in the log and the cookie),
  # `ttl_seconds` (the mint-to-exchange window; default 300, clamped to 10–900),
  # `session_ttl_seconds` (the exchanged session's lifetime; default 900, clamped to
  # 60–3600). → 201 with the plaintext `token`, once, beside the row.
  def create
    ttl_seconds = clamped_seconds(:ttl_seconds, ConsoleLoginToken::TTL_SECONDS, ConsoleLoginToken::DEFAULT_TTL_SECONDS)
    session_ttl_seconds = clamped_seconds(:session_ttl_seconds, ConsoleLoginToken::SESSION_TTL_SECONDS, ConsoleLoginToken::DEFAULT_SESSION_TTL_SECONDS)
    return if performed?

    token, plaintext = ConsoleLoginToken.mint!(
      principal: params[:principal].to_s,
      ttl_seconds: ttl_seconds,
      session_ttl_seconds: session_ttl_seconds,
      minted_from_ip: request.remote_ip
    )
    log_lifecycle("minted", token, "expires_at=#{token.expires_at.iso8601} session_ttl_seconds=#{token.session_ttl_seconds}")

    response.headers["Cache-Control"] = "no-store"
    render json: { token: plaintext, console_login_token: token.as_api_json }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_console_login_error("Unprocessable Entity", e.record.errors.full_messages, status: :unprocessable_entity)
  end

  # POST /console_login_tokens/:id/revoke → 200 with the row and `revoked`, which is
  # true only for the call that changed it. 404 for an id that was never minted.
  def revoke
    token = ConsoleLoginToken.find(params[:id])
    revoked = token.revoke!
    log_lifecycle(revoked ? "revoked" : "left #{token.status}", token)

    render json: { console_login_token: token.as_api_json, revoked: revoked }
  end

  private

  # An absent value is the default; a present one must be an integer, and is clamped
  # into the range the model accepts. Anything else renders a 422 and returns nil,
  # so the action checks `performed?` before going on.
  def clamped_seconds(name, range, default)
    raw = params[name]
    return default if raw.blank?

    value = Integer(raw.to_s, exception: false)
    if value.nil?
      render_console_login_error("Unprocessable Entity", "#{name} must be an integer number of seconds", status: :unprocessable_entity)
      return nil
    end

    value.clamp(range)
  end

  # WARN, so it ships to obs: which token was minted or revoked, for whom, from where,
  # is the audit trail. `inspect` quotes the principal so a newline in it cannot
  # forge a second log line.
  def log_lifecycle(verb, token, detail = nil)
    Rails.logger.warn(
      "[console_login] #{verb} token id=#{token.id} for #{token.principal.inspect} " \
      "from #{request.remote_ip}#{detail ? " #{detail}" : ""}"
    )
  end

  # A JSON client, so the 401 carries the reason in the body. The realm challenge
  # stays on a configured realm — `curl -u` does not care, and a browser that gets
  # here can still sign in — and is withheld when there is nothing to satisfy it.
  def refuse_operator(realm_configured: true)
    message = if realm_configured
      "Minting and revoking console login tokens needs the operator credential (HTTP Basic, the same one " \
        "#{OperatorHttpBasicAuth::PASSWORD_ENV} sets for /supervisor)."
    else
      "#{OperatorHttpBasicAuth::PASSWORD_ENV} is unset or blank, so console login tokens cannot be minted or revoked. " \
        "Set it in the deployment's secrets to use them."
    end

    response.headers["WWW-Authenticate"] = %(Basic realm="#{OperatorHttpBasicAuth::REALM}") if realm_configured
    render_console_login_error("Unauthorized", message, status: :unauthorized)
  end
end
