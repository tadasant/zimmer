# frozen_string_literal: true

# The environment gate in front of every console-login endpoint (tadasant/zimmer#220).
#
# With `CONSOLE_LOGIN_ENABLED` anything but `true`, minting, exchanging, revoking and
# reading a console session all answer 403 naming the variable — before any
# credential is looked at, so a closed deployment neither challenges for the
# operator password nor reveals whether a token exists. Nothing sets the variable by
# default in any environment: the web UI has no login gate yet, so the cookie the
# exchange issues authorizes nothing the perimeter does not already grant, and an
# automated actor cannot mint its way into a deployment that never opted in.
#
# Read on every request, never memoized, so turning the flag off takes effect
# without a restart wherever the process environment can change.
module ConsoleLoginGate
  extend ActiveSupport::Concern

  included do
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
