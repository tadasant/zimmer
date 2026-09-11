# frozen_string_literal: true

# Exchange a console login token for a console session, and read the session back
# (tadasant/zimmer#220): the automated-actor half of the agent-login primitive.
#
# The exchange takes the token in a JSON request **body** and nowhere else. A token in
# a query string has already been written to access logs and may be in a `Referer`
# header, so it counts as leaked: it is revoked on sight, if it is a whole valid
# token, and the request is refused with a 400 whatever the body says.
#
# On success the response sets the console session cookie (ConsoleSession) and answers
# 200 with what the cookie carries. On any refusal there is no cookie, and the status
# says which kind of refusal it was:
#
#   401 `invalid`   malformed, no such id, or a secret that does not match — one
#                   answer for all three, so the response does not distinguish them
#   401 `expired`   the secret matched, the token was never used, and its window is over
#   409 `consumed`  the token was already exchanged — **the tripwire**. An actor that
#                   minted this token and has not used it should not retry it: revoke
#                   the id, alarm, mint afresh
#   409 `revoked`   revoked before it was exchanged
#
# The exchange itself is one conditional UPDATE in ConsoleLoginToken.exchange!, so two
# requests racing on one token get one 200 and one 409.
#
# JSON-only (ConsoleLoginGate#require_json_body) is also what closes login CSRF: a
# cross-site page cannot submit a form here to log an operator's browser in as a
# principal of its choosing.
class ConsoleLoginController < ActionController::API
  include ActionController::Cookies
  include ConsoleLoginGate
  include ConsoleSession

  before_action :refuse_token_in_query_string, only: :create
  before_action :require_json_body, only: :create

  # POST /console_login — JSON body `{"token": "zlt_…"}`. → 200 `{console_login}` plus
  # the cookie.
  def create
    presented = request.request_parameters["token"]
    if presented.blank?
      return render_console_login_error("Bad Request", "token is required in the JSON request body", status: :bad_request)
    end

    exchange = ConsoleLoginToken.exchange!(presented, consumed_from_ip: request.remote_ip)

    if exchange.exchanged?
      login = issue_console_session(exchange.token)
      Rails.logger.warn(
        "[console_login] exchanged token id=#{exchange.token.id} for #{exchange.token.principal.inspect} " \
        "from #{request.remote_ip}; session expires_at=#{login.expires_at.iso8601}"
      )
      response.headers["Cache-Control"] = "no-store"
      render json: { console_login: login.as_json }
    else
      refuse_exchange(exchange)
    end
  end

  # GET /console_login → 200 `{console_login}` for a request carrying a live console
  # session cookie, 401 otherwise. The one reader of the cookie, and the way an actor
  # checks its exchange took before it drives the UI.
  def show
    login = current_console_login

    if login
      render json: { console_login: login.as_json }
    else
      render_console_login_error("Unauthorized", "No console session: exchange a console login token first.", status: :unauthorized)
    end
  end

  private

  # Runs before the JSON check, so a token in a URL is killed however the rest of the
  # request looks. Revoking needs the whole valid token, so this cannot be used to
  # revoke a token the caller does not hold.
  def refuse_token_in_query_string
    leaked = request.query_parameters["token"]
    return if leaked.blank?

    revoked = ConsoleLoginToken.revoke_presented!(leaked)
    Rails.logger.warn(
      "[console_login] token presented in a query string from #{request.remote_ip}; " \
      "#{revoked ? "revoked it" : "not a live token, nothing revoked"}"
    )

    message = "Send the token in the JSON request body, not the query string: a URL is logged and forwarded."
    message += " That token has been revoked because it was in a URL; mint a new one." if revoked
    render_console_login_error("Bad Request", message, status: :bad_request, revoked: revoked)
  end

  # Every refusal is WARN with the id when there is one: a consumed or revoked token
  # being presented again is exactly the event single-use exists to surface, and a
  # wrong secret against a real id is someone guessing.
  def refuse_exchange(exchange)
    token = exchange.token
    reason = exchange.refusal
    label = token ? "token id=#{token.id} (#{token.principal.inspect}, status=#{token.status})" : "token"

    Rails.logger.warn("[console_login] refused exchange of #{label} from #{request.remote_ip}: #{reason}")

    case reason
    when :consumed
      render_console_login_error("Conflict", "This token was already exchanged#{" at #{token.consumed_at.iso8601}" if token.consumed_at}. Do not retry it: revoke it and mint a new one.", status: :conflict, reason: "consumed")
    when :revoked
      render_console_login_error("Conflict", "This token was revoked before it was exchanged.", status: :conflict, reason: "revoked")
    when :expired
      render_console_login_error("Unauthorized", "This token expired at #{token.expires_at.iso8601} without being exchanged.", status: :unauthorized, reason: "expired")
    else
      render_console_login_error("Unauthorized", "Invalid console login token.", status: :unauthorized, reason: "invalid")
    end
  end
end
