require "test_helper"

# The Host allow-list production and staging boot with, driven through the real
# HostAuthorization middleware with the same `/up` exclusion the environments
# configure, one Host per way the deployment is actually reached.
class AllowedHostsTest < ActiveSupport::TestCase
  PROD_ENV = {
    "ZIMMER_PROD_BASE_URL" => "https://zimmer.tadasant.com",
    "APP_HOST" => "zimmer.tadasant.com",
    "ZIMMER_TAILNET_HOSTNAME" => "zimmer"
  }.freeze

  def status_for(hosts, host, path: "/", forwarded_host: nil)
    app = ActionDispatch::HostAuthorization.new(->(_env) { [ 200, {}, [ "ok" ] ] }, hosts,
      exclude: ->(request) { request.path == "/up" })
    env = Rack::MockRequest.env_for("http://placeholder#{path}")
    env["HTTP_HOST"] = host
    env["HTTP_X_FORWARDED_HOST"] = forwarded_host if forwarded_host
    app.call(env).first
  end

  test "every Host production receives is allowed" do
    hosts = AllowedHosts.for("production", env: PROD_ENV)

    {
      "zimmer.tadasant.com" => "Cloudflare, the host Caddy :443, on-box sessions pinned to the domain",
      "Zimmer.Tadasant.com:443" => "case and port do not matter",
      "100.101.102.103" => "a deploy health check at http://<tailnet-ip>/up/deep through Caddy :80",
      "100.101.102.103:80" => "the same, with the port spelled out",
      "[fd7a:115c:a1e0::1]:80" => "a tailnet IPv6 address",
      "zimmer" => "http://<tailnet-hostname>/ over MagicDNS",
      "zimmer.tail1234.ts.net" => "the MagicDNS FQDN",
      "localhost:8080" => "curl against kamal-proxy on the box"
    }.each do |host, why|
      assert_equal 200, status_for(hosts, host, path: "/up/deep"), "#{host} (#{why}) must be allowed"
    end
  end

  test "a foreign Host, or a foreign X-Forwarded-Host, is refused" do
    hosts = AllowedHosts.for("production", env: PROD_ENV)

    %w[evil.example zimmer.tadasant.com.evil.example evilzimmer.tail1.ts.net staging.zimmer.tadasant.com].each do |host|
      assert_equal 403, status_for(hosts, host), "#{host} must be refused"
    end
    assert_equal 403, status_for(hosts, "zimmer.tadasant.com", forwarded_host: "evil.example")
  end

  test "/up answers whatever the Host, so kamal-proxy's health gate never meets the list" do
    assert_equal 200, status_for(AllowedHosts.for("production", env: PROD_ENV), "zimmer-web-production-abc123:80", path: "/up")
  end

  test "staging reads its own base URL and tailnet name" do
    hosts = AllowedHosts.for("staging", env: {
      "ZIMMER_STAGING_BASE_URL" => "https://staging.zimmer.tadasant.com", "ZIMMER_TAILNET_HOSTNAME" => "zimmer-staging"
    })

    assert_equal 200, status_for(hosts, "staging.zimmer.tadasant.com")
    assert_equal 200, status_for(hosts, "zimmer-staging")
    assert_equal 403, status_for(hosts, "zimmer.tadasant.com")
  end

  test "ZIMMER_ALLOWED_HOSTS adds hostnames, and a leading dot admits subdomains" do
    hosts = AllowedHosts.for("production", env: PROD_ENV.merge("ZIMMER_ALLOWED_HOSTS" => "alt.example.com, .example.net"))

    assert_equal 200, status_for(hosts, "alt.example.com")
    assert_equal 200, status_for(hosts, "a.example.net")
    assert_equal 403, status_for(hosts, "other.example.com")
  end

  test "ZIMMER_ALLOWED_HOSTS=* turns the check off" do
    assert_nil AllowedHosts.for("production", env: PROD_ENV.merge("ZIMMER_ALLOWED_HOSTS" => "*"))
  end

  test "with no hostname configured the check stays off rather than refusing every visitor" do
    assert_nil AllowedHosts.for("production", env: {})
    assert_nil AllowedHosts.for("production", env: { "ZIMMER_PROD_BASE_URL" => AppUrl::PLACEHOLDER_PROD_BASE_URL })
  end

  test "an APP_HOST alone is enough, and a malformed tailnet name is ignored" do
    hosts = AllowedHosts.for("production", env: { "APP_HOST" => "zimmer.example.org:443", "ZIMMER_TAILNET_HOSTNAME" => "bad name" })

    assert_equal 200, status_for(hosts, "zimmer.example.org")
    assert_equal 403, status_for(hosts, "bad name")
  end
end
