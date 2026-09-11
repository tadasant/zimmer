# frozen_string_literal: true

# The web-console session a ConsoleLoginToken exchange issues, and the one place it
# is read and written.
#
# The session is an encrypted cookie, separate from the Rails session cookie that
# carries the flash and the CSRF token: coupling the two would make a login's expiry
# the CSRF token's expiry and vice versa. Its lifetime is the token row's
# `session_ttl_seconds`, decided at mint, and it is on the wire as `Max-Age` (with a
# matching `Expires`). The browser drops it then; the server does not depend on that.
# Rails embeds the same instant in the encrypted payload and the jar refuses the
# cookie past it, and `read_console_login` checks the payload's own `expires_at` as
# well — so a client that keeps the cookie longer than it was told to holds nothing.
#
# `HttpOnly`, `SameSite=Lax`, and `Secure` everywhere except a local (development or
# test) deployment answering over plain HTTP.
#
# No controller gates on `current_console_login`: the web UI has no login, and the
# perimeter is the boundary. This concern is what a UI gate would include, and
# `ConsoleLoginController#show` is the one reader, which proves an exchanged cookie
# reads back.
module ConsoleSession
  extend ActiveSupport::Concern

  COOKIE = "zimmer_console_session"

  # What the cookie carries: the authority the token row baked in, and when it ends.
  # Never the token, never the digest.
  Login = Data.define(:token_id, :principal, :role, :expires_at) do
    def as_json(*)
      { "token_id" => token_id, "principal" => principal, "role" => role, "expires_at" => expires_at.iso8601 }
    end
  end

  private

  # Write the cookie for an exchanged token. Called once, by the exchange.
  def issue_console_session(token, now: Time.current)
    expires_at = now + token.session_ttl_seconds.seconds
    login = Login.new(token_id: token.id, principal: token.principal, role: token.role, expires_at: expires_at)

    # `expires` is what Rails embeds in the encrypted payload; `max_age` is what the
    # browser honours first, and it is the attribute the issue asks for. Both name
    # the same instant.
    cookies.encrypted[COOKIE] = {
      value: login.as_json,
      expires: expires_at,
      max_age: token.session_ttl_seconds,
      httponly: true,
      same_site: :lax,
      secure: console_cookie_secure?,
      path: "/"
    }

    @current_console_login = login
  end

  # The login the request carries, or nil. Memoized per request.
  def current_console_login
    return @current_console_login if defined?(@current_console_login)

    @current_console_login = read_console_login
  end

  # nil for anything but a payload this concern wrote that has not expired —
  # including one missing a field.
  def read_console_login(now: Time.current)
    payload = cookies.encrypted[COOKIE]
    return nil unless payload.is_a?(Hash)
    return nil unless payload.values_at("token_id", "principal", "role", "expires_at").all?(&:present?)

    expires_at = Time.iso8601(payload["expires_at"].to_s)
    return nil if expires_at <= now

    Login.new(
      token_id: payload["token_id"],
      principal: payload["principal"],
      role: payload["role"],
      expires_at: expires_at
    )
  rescue ArgumentError
    # `Time.iso8601` on an `expires_at` that is not a timestamp.
    nil
  end

  # `Secure` outside local. A deployed environment always gets it — production
  # answers behind `assume_ssl`, and a staging deploy over plain HTTP gets a cookie
  # the browser will not send back, which is the safe failure. Development and test
  # answer over HTTP and get it only if the request itself was TLS.
  def console_cookie_secure?
    !Rails.env.local? || request.ssl?
  end
end
