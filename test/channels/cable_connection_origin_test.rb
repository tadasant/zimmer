require "test_helper"

# ActionCable's WebSocket origin check (ActionCable::Connection::Base#allow_request_origin?)
# compares HTTP_ORIGIN against "#{proto}://#{HTTP_HOST}", where proto comes from
# Rack::Request#ssl?. Production/staging run behind `config.assume_ssl`, which forces
# ssl? to true for *every* request, while the droplet actually answers on plain HTTP over
# the tailnet. The scheme-only mismatch made Rails reject its own tailnet clients.
#
# These tests drive the check through whatever class ActionCable will really instantiate
# (config.connection_class), so they exercise the same code path as a live /cable upgrade.
class CableConnectionOriginTest < ActiveSupport::TestCase
  # Mirrors ActionDispatch::AssumeSSL, the middleware `config.assume_ssl = true` inserts:
  # it marks every request as TLS-terminated regardless of how it actually arrived.
  def build_env(origin:, host:, assume_ssl: true)
    env = Rack::MockRequest.env_for(
      "/cable",
      "HTTP_HOST" => host,
      "HTTP_ORIGIN" => origin,
      "HTTP_CONNECTION" => "Upgrade",
      "HTTP_UPGRADE" => "websocket"
    )

    if assume_ssl
      env["HTTPS"] = "on"
      env["HTTP_X_FORWARDED_PROTO"] = "https"
      env["rack.url_scheme"] = "https"
    end

    env
  end

  def allowed?(origin:, host:, assume_ssl: true)
    connection_class = ActionCable.server.config.connection_class.call
    connection = connection_class.new(ActionCable.server, build_env(origin:, host:, assume_ssl:))
    connection.send(:allow_request_origin?)
  end

  test "accepts a plain-HTTP origin matching the request host under assume_ssl" do
    # The production regression: a browser on the tailnet loads http://zimmer, and Turbo's
    # cable consumer opens ws://zimmer/cable with Origin: http://zimmer.
    assert allowed?(origin: "http://zimmer", host: "zimmer")
  end

  test "accepts an HTTPS origin matching the request host" do
    assert allowed?(origin: "https://zimmer.example.com", host: "zimmer.example.com")
  end

  test "accepts a matching host that carries an explicit port" do
    assert allowed?(origin: "http://zimmer:3000", host: "zimmer:3000")
  end

  test "accepts a matching host when the request is not TLS-terminated" do
    assert allowed?(origin: "http://zimmer", host: "zimmer", assume_ssl: false)
  end

  test "matches the host case-insensitively" do
    assert allowed?(origin: "http://Zimmer", host: "zimmer")
  end

  test "rejects a cross-origin request" do
    refute allowed?(origin: "https://evil.example.com", host: "zimmer")
  end

  test "rejects an origin whose host merely resembles the request host" do
    refute allowed?(origin: "http://zimmer.evil.example.com", host: "zimmer")
  end

  test "rejects an origin on a different port than the request host" do
    refute allowed?(origin: "http://zimmer:4000", host: "zimmer:3000")
  end

  test "rejects a non-HTTP origin scheme" do
    refute allowed?(origin: "file://zimmer", host: "zimmer")
  end

  test "rejects an opaque origin" do
    refute allowed?(origin: "null", host: "zimmer")
  end

  test "rejects a request with no origin header" do
    refute allowed?(origin: nil, host: "zimmer")
  end
end
