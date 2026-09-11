# frozen_string_literal: true

# Exchange a console login token for a console session, and read the session back
# (tadasant/zimmer#220): the automated-actor half of the agent-login primitive.
#
# The exchange takes the token in the request **body** and nowhere else. A token in a
# query string lands in access logs and `Referer` headers, so one presented that way
# is refused without being looked at — the actor is told to move it, and the token is
# still live.
#
# On success the response sets the console session cookie (ConsoleSession) and answers
# 200 with what the cookie carries. On any refusal there is no cookie, and the status
# says which kind of refusal it was:
#
#   401 `invalid`   malformed, no such id, or a secret that does not match — one
#                   answer for all three, so a guess at an id learns nothing
#   401 `expired`   the secret matched, the token was never used, and its window is over
#   409 `consumed`  the token was already exchanged — **the tripwire**. An actor that
#                   minted this token and has not used it should not retry it: revoke
#                   the id, alarm, mint afresh
#   409 `revoked`   revoked before it was exchanged
#
# The exchange itself is one conditional UPDATE in ConsoleLoginToken.exchange!, so two
# requests racing on one token get one 200 and one 409.
#
# No CSRF check on the exchange, and none is needed: the request carries no cookie of
# consequence and the only thing it can do is log the *presenting* browser in as the
# token's principal. Anyone holding a token can do that directly.
#
# Everything is closed unless `CONSOLE_LOGIN_ENABLED` is `true` — see ConsoleLoginGate.
class ConsoleLoginController < ActionController::API
  include ControllerDatabaseRetry
  include ActionController::Cookies
  include ConsoleLoginGate
  include ConsoleSession

  # POST /console_login — body `token`. → 200 `{console_login}` plus the cookie.
  def create
    presented = presented_token
    return if performed?

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
  # session cookie, 401 otherwise. The one consumer of the cookie today, and the way
  # an actor checks its exchange took before it drives the UI.
  def show
    login = current_console_login

    if login
      render json: { console_login: login.as_json }
    else
      render_console_login_error("Unauthorized", "No console session: exchange a console login token first.", status: :unauthorized)
    end
  end

  private

  # The body's `token`, and only the body's. `params` merges the query string in,
  # so it is read from `request_parameters` — which is the parsed JSON body for a
  # JSON request and the form fields otherwise — and a token that is *only* in the
  # query string is refused with an explanation rather than silently ignored.
  def presented_token
    presented = request.request_parameters["token"]
    return presented if presented.present?

    if request.query_parameters["token"].present?
      render_console_login_error(
        "Bad Request",
        "Send the token in the request body, not the query string: a URL is logged and forwarded, a body is not. The token has not been consumed.",
        status: :bad_request
      )
    else
      render_console_login_error("Bad Request", "token is required in the request body", status: :bad_request)
    end
    nil
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
