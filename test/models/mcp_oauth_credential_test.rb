require "test_helper"

class McpOauthCredentialTest < ActiveSupport::TestCase
  test "validates presence of required fields" do
    credential = McpOauthCredential.new

    assert_not credential.valid?
    assert_includes credential.errors[:server_name], "can't be blank"
    assert_includes credential.errors[:server_url], "can't be blank"
    assert_includes credential.errors[:credential_key], "can't be blank"
    assert_includes credential.errors[:client_id], "can't be blank"
    assert_includes credential.errors[:access_token], "can't be blank"
  end

  test "validates uniqueness of credential_key" do
    existing = mcp_oauth_credentials(:notion)

    duplicate = McpOauthCredential.new(
      server_name: "other-server",
      server_url: "https://other.example.com",
      credential_key: existing.credential_key,
      client_id: "client-123",
      access_token: "token-123"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:credential_key], "has already been taken"
  end

  test "compute_credential_key creates consistent key format" do
    config = {
      type: "streamable-http",
      url: "https://mcp.notion.com/v1/mcp",
      headers: {}
    }

    key = McpOauthCredential.compute_credential_key("notion", config)

    assert_match(/\Anotion\|[a-f0-9]{16}\z/, key)
  end

  test "compute_credential_key normalizes streamable-http to http" do
    config_streamable = {
      type: "streamable-http",
      url: "https://example.com/mcp",
      headers: {}
    }
    config_http = {
      type: "http",
      url: "https://example.com/mcp",
      headers: {}
    }

    key_streamable = McpOauthCredential.compute_credential_key("test", config_streamable)
    key_http = McpOauthCredential.compute_credential_key("test", config_http)

    # Both should produce the same key since streamable-http normalizes to http
    assert_equal key_streamable, key_http
  end

  test "active? returns true when expires_at is nil" do
    credential = mcp_oauth_credentials(:notion)
    credential.expires_at = nil

    assert credential.active?
  end

  test "active? returns true when expires_at is in the future" do
    credential = mcp_oauth_credentials(:notion)
    credential.expires_at = 1.hour.from_now

    assert credential.active?
  end

  test "active? returns false when expires_at is in the past" do
    credential = mcp_oauth_credentials(:notion)
    credential.expires_at = 1.hour.ago

    assert_not credential.active?
  end

  test "needs_refresh? returns false when expires_at is nil" do
    credential = mcp_oauth_credentials(:notion)
    credential.expires_at = nil

    assert_not credential.needs_refresh?
  end

  test "needs_refresh? returns true when token expires within 15 minutes" do
    credential = mcp_oauth_credentials(:notion)
    credential.expires_at = 10.minutes.from_now

    assert credential.needs_refresh?
  end

  test "needs_refresh? returns false when token expires after 15 minutes" do
    credential = mcp_oauth_credentials(:notion)
    credential.expires_at = 30.minutes.from_now

    assert_not credential.needs_refresh?
  end

  test "can_refresh? returns true when refresh_token and token_endpoint are present" do
    credential = mcp_oauth_credentials(:notion)
    credential.refresh_token = "refresh-token-123"
    credential.token_endpoint = "https://oauth.example.com/token"

    assert credential.can_refresh?
  end

  test "can_refresh? returns false when refresh_token is missing" do
    credential = mcp_oauth_credentials(:notion)
    credential.refresh_token = nil
    credential.token_endpoint = "https://oauth.example.com/token"

    assert_not credential.can_refresh?
  end

  test "for_credential_key scope finds by credential_key" do
    credential = mcp_oauth_credentials(:notion)

    found = McpOauthCredential.for_credential_key(credential.credential_key).first

    assert_equal credential, found
  end

  test "active scope excludes expired credentials" do
    credential = mcp_oauth_credentials(:notion)
    credential.update!(expires_at: 1.hour.ago)

    assert_not_includes McpOauthCredential.active, credential
  end

  test "active scope includes non-expired credentials" do
    credential = mcp_oauth_credentials(:notion)
    credential.update!(expires_at: 1.hour.from_now)

    assert_includes McpOauthCredential.active, credential
  end

  test "refresh! includes the RFC 8707 resource parameter when resource is present" do
    credential = mcp_oauth_credentials(:expired_with_refresh)
    credential.update!(resource: "https://mcp.notion.com")
    captured_params = nil

    response = build_token_response({ "access_token" => "new-tok", "expires_in" => 3600 })

    Net::HTTP.stub(:post_form, ->(_uri, params) { captured_params = params; response }) do
      assert credential.refresh!
    end

    assert_equal "https://mcp.notion.com", captured_params[:resource]
  end

  test "refresh! omits the resource parameter when resource is blank" do
    credential = mcp_oauth_credentials(:expired_with_refresh)
    credential.update!(resource: nil)
    captured_params = nil

    response = build_token_response({ "access_token" => "new-tok", "expires_in" => 3600 })

    Net::HTTP.stub(:post_form, ->(_uri, params) { captured_params = params; response }) do
      assert credential.refresh!
    end

    assert_not captured_params.key?(:resource)
  end

  test "refresh! unwraps a nested authed_user.access_token (Slack rotation shape)" do
    credential = mcp_oauth_credentials(:expired_with_refresh)

    # Slack token rotation returns the refreshed user token nested under authed_user,
    # exactly like the initial exchange — the refresh path must unwrap it too.
    response = build_token_response({
      "ok" => true,
      "authed_user" => {
        "access_token" => "xoxp-rotated",
        "refresh_token" => "xoxe-next",
        "expires_in" => 43200
      }
    })

    Net::HTTP.stub(:post_form, ->(_uri, _params) { response }) do
      assert credential.refresh!
    end

    credential.reload
    assert_equal "xoxp-rotated", credential.access_token
    assert_equal "xoxe-next", credential.refresh_token
  end

  test "refresh! returns false and preserves the existing token when the 200 response has no usable token" do
    credential = mcp_oauth_credentials(:expired_with_refresh)
    original_access = credential.access_token
    original_refresh = credential.refresh_token

    # A malformed/empty 200 must not null out a working credential.
    response = build_token_response({ "ok" => false, "error" => "internal_error" })

    Net::HTTP.stub(:post_form, ->(_uri, _params) { response }) do
      assert_not credential.refresh!
    end

    credential.reload
    assert_equal original_access, credential.access_token
    assert_equal original_refresh, credential.refresh_token
  end

  test "refresh! permanent failure drops the refresh token but preserves a still-valid access token" do
    credential = mcp_oauth_credentials(:expiring_soon)
    original_token = credential.access_token
    original_expires_at = credential.expires_at

    response = build_error_response(401, { "error" => "invalid_grant" })

    Net::HTTP.stub(:post_form, response) do
      assert_not credential.refresh!
    end

    credential.reload
    # The still-valid access token is preserved — a live session is not stranded
    assert_equal original_token, credential.access_token
    assert_equal original_expires_at.to_i, credential.expires_at.to_i
    assert credential.active?
    # The dead refresh token is dropped so it can never be re-sent
    assert_nil credential.refresh_token
    assert_not credential.can_refresh?
    # Re-auth is not forced while the access token remains valid
    assert_not credential.requires_reauth?
  end

  test "refresh! permanent failure on an already-expired credential force-expires and requires reauth" do
    credential = mcp_oauth_credentials(:expired_with_refresh)
    assert_not credential.active?, "fixture should already be expired"

    response = build_error_response(401, { "error" => "invalid_grant" })

    Net::HTTP.stub(:post_form, response) do
      assert_not credential.refresh!
    end

    credential.reload
    assert_nil credential.refresh_token
    assert_not credential.can_refresh?
    assert_not credential.active?
    assert credential.requires_reauth?
  end

  test "refresh! treats a 400 with a non-JSON (HTML) body as a permanent failure and does not log an error" do
    credential = mcp_oauth_credentials(:expiring_soon)

    # Some token endpoints reject a dead refresh token with a bare HTML 400
    # "Bad Request" rather than a spec-compliant JSON error body. This must
    # still be classified permanent (WARN + natural re-auth), not logged as an
    # ERROR that pages the production #alerts channel.
    html_body = "<!DOCTYPE html>\n<html><body><pre>Bad Request</pre></body></html>"
    response = build_raw_response(400, html_body)

    logged = capture_logger_levels do
      Net::HTTP.stub(:post_form, response) do
        assert_not credential.refresh!
      end
    end

    assert_not_includes logged, :error, "a non-JSON 4xx refresh failure must not hit the ERROR (paging) path"
    assert_includes logged, :warn, "a permanent refresh failure should log a WARN"

    credential.reload
    # Routed through invalidate_refresh_token!: dead refresh token dropped.
    assert_nil credential.refresh_token
    assert_not credential.can_refresh?
  end

  test "refresh! treats a 401 with a non-JSON body as a permanent failure" do
    credential = mcp_oauth_credentials(:expiring_soon)

    response = build_raw_response(401, "Unauthorized")

    logged = capture_logger_levels do
      Net::HTTP.stub(:post_form, response) do
        assert_not credential.refresh!
      end
    end

    assert_not_includes logged, :error
    assert_includes logged, :warn

    credential.reload
    assert_nil credential.refresh_token
  end

  test "refresh! keeps a 5xx transient failure on the loud ERROR path" do
    credential = mcp_oauth_credentials(:expiring_soon)
    original_refresh_token = credential.refresh_token

    response = build_raw_response(503, "Service Unavailable")

    logged = capture_logger_levels do
      Net::HTTP.stub(:post_form, response) do
        assert_not credential.refresh!
      end
    end

    assert_includes logged, :error, "a 5xx outage must stay loud so real problems surface"

    credential.reload
    # A transient failure must not drop the refresh token — we retry later.
    assert_equal original_refresh_token, credential.refresh_token
    assert credential.can_refresh?
  end

  test "refresh! treats a 429 rate-limit as transient, not permanent, and keeps the refresh token" do
    credential = mcp_oauth_credentials(:expiring_soon)
    original_refresh_token = credential.refresh_token

    response = build_raw_response(429, "Too Many Requests")

    logged = capture_logger_levels do
      Net::HTTP.stub(:post_form, response) do
        assert_not credential.refresh!
      end
    end

    # A rate limit is transient: stay loud and, crucially, do NOT drop a
    # still-good refresh token — the next cron run retries.
    assert_includes logged, :error
    assert_not_includes logged, :warn

    credential.reload
    assert_equal original_refresh_token, credential.refresh_token
    assert credential.can_refresh?
  end

  private

  # Captures which Rails.logger severity levels were emitted during the block.
  def capture_logger_levels
    levels = []
    fake = Object.new
    %i[error warn info debug].each do |level|
      fake.define_singleton_method(level) { |*_args| levels << level }
    end
    Rails.stub(:logger, fake) { yield }
    levels
  end

  def build_token_response(body_hash)
    response = Net::HTTPSuccess.new("1.1", "200", "OK")
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:body) { body_hash.to_json }
    response
  end

  def build_error_response(status, body_hash)
    response = Net::HTTPUnauthorized.new("1.1", status.to_s, "Unauthorized")
    response.define_singleton_method(:code) { status.to_s }
    response.define_singleton_method(:body) { body_hash.to_json }
    response
  end

  # A response whose body is a raw string (e.g. an HTML error page), not JSON,
  # using the Net class that actually corresponds to the status.
  def build_raw_response(status, body_string)
    klass = Net::HTTPResponse::CODE_TO_OBJ[status.to_s] || Net::HTTPResponse
    response = klass.new("1.1", status.to_s, "")
    response.define_singleton_method(:code) { status.to_s }
    response.define_singleton_method(:body) { body_string }
    response
  end
end
