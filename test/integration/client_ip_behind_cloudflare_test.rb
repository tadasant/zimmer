# frozen_string_literal: true

require "test_helper"

# Behind the optional Cloudflare edge, every request reaches the app from the box itself:
# Cloudflare edge -> cloudflared (host network) -> kamal-proxy :8080 -> the web container.
# Zimmer keys a rate limit (Quick Router) and its refusal logs on `request.remote_ip`, so that
# value has to stay the real client's.
#
# It does, with no Cloudflare-specific code, and these cases pin why. The header shapes are
# the ones observed end to end through a real Cloudflare edge, cloudflared and kamal-proxy
# v0.9.2 (docs/operate/deploying.md#optional-cloudflare-edge):
#
#   - the edge APPENDS the client address it saw to any X-Forwarded-For the client sent;
#   - kamal-proxy (forward_headers defaults on with ssl: false) appends its docker peer;
#   - Rails takes the right-most address that is not a trusted (private/loopback) proxy.
#
# So a forged X-Forwarded-For lands to the LEFT of the edge's entry and is never chosen. And
# CF-Connecting-IP is deliberately NOT read: the tailnet path goes through Caddy, which passes
# that header through from any tailnet client untouched, so trusting it would let a tailnet
# peer pick its own address. X-Forwarded-For is safe on that path too, because Caddy REPLACES
# it with the peer it actually saw.
class ClientIpBehindCloudflareTest < ActiveSupport::TestCase
  # A real client, the edge's view of it, and the docker gateway kamal-proxy connects from.
  CLIENT = "198.51.100.23"
  KAMAL_PROXY_PEER = "172.18.0.1"
  KAMAL_PROXY_CONTAINER = "172.18.0.5"

  def remote_ip_for(headers)
    env = Rack::MockRequest.env_for("/", { "REMOTE_ADDR" => KAMAL_PROXY_CONTAINER }.merge(headers))
    config = Rails.application.config.action_dispatch
    app = ActionDispatch::RemoteIp.new(->(e) { [ 200, {}, [ ActionDispatch::Request.new(e).remote_ip ] ] },
      config.ip_spoofing_check, config.trusted_proxies)
    app.call(env).last.first
  end

  test "the app trusts only Rails' default proxies, which is what the reasoning above assumes" do
    assert_nil Rails.application.config.action_dispatch.trusted_proxies,
      "trusted_proxies is configured; re-check that a forged X-Forwarded-For entry still cannot win"
  end

  test "through the tunnel, the edge-observed client wins over a forged X-Forwarded-For" do
    ip = remote_ip_for(
      "HTTP_X_FORWARDED_FOR" => "10.9.9.9, 6.6.6.6,#{CLIENT}, #{KAMAL_PROXY_PEER}",
      "HTTP_CF_CONNECTING_IP" => CLIENT
    )
    assert_equal CLIENT, ip
  end

  test "through the tunnel with no client-supplied header, the client is the edge's entry" do
    assert_equal CLIENT, remote_ip_for("HTTP_X_FORWARDED_FOR" => "#{CLIENT}, #{KAMAL_PROXY_PEER}")
  end

  test "over the tailnet, a forged CF-Connecting-IP is ignored" do
    tailnet_peer = "100.101.102.103"
    ip = remote_ip_for(
      # Caddy replaced X-Forwarded-For with the peer it saw; kamal-proxy appended its own.
      "HTTP_X_FORWARDED_FOR" => "#{tailnet_peer}, #{KAMAL_PROXY_PEER}",
      "HTTP_CF_CONNECTING_IP" => "1.2.3.4"
    )
    assert_equal tailnet_peer, ip
  end
end
