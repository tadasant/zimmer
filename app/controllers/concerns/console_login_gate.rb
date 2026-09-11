# frozen_string_literal: true

# The gates in front of every console-login endpoint (tadasant/zimmer#220).
#
# **The env gate.** With `CONSOLE_LOGIN_ENABLED` anything but `true`, minting,
# exchanging, revoking and reading a console session all answer 403 naming the
# variable — before any credential is looked at, so a closed deployment neither
# challenges for the operator password nor reveals whether a token exists. Nothing
# sets the variable by default in any environment: the web UI has no login gate, so
# the cookie the exchange issues authorizes nothing the perimeter does not already
# grant, and an automated actor cannot mint its way into a deployment that never
# opted in. Read on every request, never memoized.
#
# **JSON only, on every write.** `require_json_body` refuses anything but
# `Content-Type: application/json` with a 415. That is the CSRF defence, and it is
# the whole of it: these controllers are `ActionController::API`, with no
# authenticity token, and a browser attaches cached Basic credentials to a
# cross-site form POST. A cross-origin JSON POST is not a simple request, so the
# browser preflights it, and nothing here answers a preflight — so no page an
# operator visits can mint or revoke with their credential, or log their browser in
# with a token it chose.
#
# Parameter wrapping is off on the hosts, so a malformed body cannot be parsed —
# and raise — before the env gate has run.
module ConsoleLoginGate
  extend ActiveSupport::Concern

  JSON_MEDIA_TYPE = "application/json"

  included do
    wrap_parameters false
    before_action :require_console_login_enabled
  end

  private

  def require_console_login_enabled
    return if ConsoleLoginToken.enabled?

    Rails.logger.info(
      "[console_login] refusing #{request.request_method} #{request.path} from #{request.remote_ip}: " \
      "#{ConsoleLoginToken::ENABLED_ENV} is not \"true\", so console login is closed"
    )
    render_console_login_error(
      "Forbidden",
      "Console login is closed on this deployment: #{ConsoleLoginToken::ENABLED_ENV} is not \"true\".",
      status: :forbidden
    )
  end

  def require_json_body
    return if request.media_type == JSON_MEDIA_TYPE

    render_console_login_error(
      "Unsupported Media Type",
      "Send the request as #{JSON_MEDIA_TYPE}. Form posts are refused so that no cross-site page can submit one.",
      status: :unsupported_media_type
    )
  end

  # The same envelope as Api::BaseController#render_api_error: `message` a String,
  # `messages` the same content as an Array. Extra keys ride along.
  def render_console_login_error(error, message, status:, **extra)
    messages = Array(message).map(&:to_s)

    render json: {
      error: error,
      message: messages.join(", "),
      messages: messages
    }.merge(extra), status: status
  end
end
