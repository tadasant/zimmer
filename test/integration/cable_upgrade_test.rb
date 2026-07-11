require "test_helper"

# End-to-end coverage of the /cable WebSocket upgrade through the real Rack stack and the
# mounted ActionCable server, asserting on the ERROR records ActionCable emits — the exact
# pair production was logging every ~27s while its Turbo Streams consumer retried a rejected
# upgrade. See app/channels/application_cable/connection.rb.
class CableUpgradeTest < ActionDispatch::IntegrationTest
  # ActionCable's rack_response for a successful upgrade: the socket is hijacked, so the
  # status is the "response already handled" sentinel rather than a real HTTP status.
  UPGRADED = -1

  setup do
    @cable_log = StringIO.new
    @original_logger = ActionCable.server.config.logger
    ActionCable.server.config.logger = ActiveSupport::Logger.new(@cable_log)
  end

  teardown do
    ActionCable.server.config.logger = @original_logger
  end

  test "accepts a plain-HTTP upgrade from the host the app was reached on" do
    upgrade(origin: "http://zimmer", host: "zimmer")

    assert_equal UPGRADED, response.status
    assert_match(/Successfully upgraded to WebSocket/, @cable_log.string)
    assert_no_match(/Request origin not allowed/, @cable_log.string)
    assert_no_match(/Failed to upgrade to WebSocket/, @cable_log.string)
  end

  test "rejects a cross-origin upgrade" do
    upgrade(origin: "https://evil.example.com", host: "zimmer")

    assert_equal 404, response.status
    assert_match(/Request origin not allowed: https:\/\/evil\.example\.com/, @cable_log.string)
    assert_match(/Failed to upgrade to WebSocket/, @cable_log.string)
  end

  private
    # `assume_ssl` (production/staging) inserts ActionDispatch::AssumeSSL, which marks every
    # request as TLS-terminated no matter how it actually arrived; HTTPS=on reproduces that.
    def upgrade(origin:, host:)
      get "/cable", headers: {
        "HTTPS" => "on",
        "HTTP_HOST" => host,
        "HTTP_ORIGIN" => origin,
        "HTTP_CONNECTION" => "Upgrade",
        "HTTP_UPGRADE" => "websocket",
        "HTTP_SEC_WEBSOCKET_KEY" => "dGhlIHNhbXBsZSBub25jZQ==",
        "HTTP_SEC_WEBSOCKET_VERSION" => "13"
      }
    end
end
