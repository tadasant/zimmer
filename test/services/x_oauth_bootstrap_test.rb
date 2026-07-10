# frozen_string_literal: true

require "test_helper"

class XOauthBootstrapTest < ActiveSupport::TestCase
  def with_token_endpoint(code:, body:)
    captured = nil
    response = Net::HTTPResponse.new("1.1", code.to_s, "")
    response.stubs(:code).returns(code.to_s)
    response.stubs(:body).returns(body.is_a?(String) ? body : body.to_json)
    mock_http = Object.new
    mock_http.define_singleton_method(:use_ssl=) { |_| }
    mock_http.define_singleton_method(:request) { |req| captured = req; response }
    result = Net::HTTP.stub(:new, mock_http) { yield }
    [ result, captured ]
  end

  # --- authorize_url ---

  test "authorize_url includes PKCE S256 challenge, scopes, redirect, and state" do
    verifier = XOauthBootstrap.generate_verifier
    state = XOauthBootstrap.generate_state
    url = XOauthBootstrap.authorize_url(client_id: "CID", verifier: verifier, state: state)
    params = URI.decode_www_form(URI(url).query).to_h

    assert_equal "https://x.com/i/oauth2/authorize", url.split("?").first
    assert_equal "code", params["response_type"]
    assert_equal "CID", params["client_id"]
    assert_equal XOauthBootstrap::DEFAULT_REDIRECT_URI, params["redirect_uri"]
    assert_equal XOauthCredential::OAUTH_SCOPES, params["scope"]
    assert_includes params["scope"], "bookmark.write"
    assert_equal state, params["state"]
    assert_equal "S256", params["code_challenge_method"]

    expected_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier)).delete("=")
    assert_equal expected_challenge, params["code_challenge"]
  end

  test "verifier and state are unpadded base64url of the right length" do
    assert_equal 43, XOauthBootstrap.generate_verifier.length # 32 bytes
    assert_equal 22, XOauthBootstrap.generate_state.length     # 16 bytes
    assert_not_includes XOauthBootstrap.generate_verifier, "="
  end

  # --- complete! ---

  test "complete! exchanges the code (Basic auth) and stores the credential" do
    body = { access_token: "acc", refresh_token: "ref", expires_in: 7200, scope: XOauthCredential::OAUTH_SCOPES }

    cred, req = with_token_endpoint(code: 200, body: body) do
      XOauthBootstrap.complete!(
        account_key: "tadasayy", env_var: "X_OAUTH_ACCESS_TOKEN", code: "auth-code",
        verifier: "the-verifier", client_id: "CID", client_secret: "SEC"
      )
    end

    assert_equal "tadasayy", cred.account_key
    assert_equal "X_OAUTH_ACCESS_TOKEN", cred.access_token_env_var
    assert_equal "acc", cred.access_token
    assert_equal "ref", cred.refresh_token
    assert_operator cred.expires_at, :>, 1.hour.from_now
    assert_includes cred.scopes, "bookmark.write"

    decoded = Base64.decode64(req["Authorization"].sub("Basic ", ""))
    assert_equal "CID:SEC", decoded
    assert_includes req.body, "grant_type=authorization_code"
    assert_includes req.body, "code_verifier=the-verifier"
  end

  test "complete! is idempotent on the env var (updates the same row)" do
    2.times do |i|
      with_token_endpoint(code: 200, body: { access_token: "a#{i}", refresh_token: "r#{i}", expires_in: 7200 }) do
        XOauthBootstrap.complete!(
          account_key: "tadasayy", env_var: "X_OAUTH_ACCESS_TOKEN", code: "c#{i}",
          verifier: "v", client_id: "CID", client_secret: "SEC"
        )
      end
    end
    assert_equal 1, XOauthCredential.where(access_token_env_var: "X_OAUTH_ACCESS_TOKEN").count
    assert_equal "r1", XOauthCredential.find_by(access_token_env_var: "X_OAUTH_ACCESS_TOKEN").refresh_token
  end

  test "complete! raises on a non-2xx token response" do
    err = assert_raises(XOauthBootstrap::ExchangeError) do
      with_token_endpoint(code: 400, body: { error: "invalid_grant" }) do
        XOauthBootstrap.complete!(account_key: "a", env_var: "X_OAUTH_ACCESS_TOKEN", code: "c",
          verifier: "v", client_id: "CID", client_secret: "SEC")
      end
    end
    assert_match(/HTTP 400/, err.message)
  end

  test "complete! raises when the response has no refresh token" do
    assert_raises(XOauthBootstrap::ExchangeError) do
      with_token_endpoint(code: 200, body: { access_token: "acc", expires_in: 7200 }) do
        XOauthBootstrap.complete!(account_key: "a", env_var: "X_OAUTH_ACCESS_TOKEN", code: "c",
          verifier: "v", client_id: "CID", client_secret: "SEC")
      end
    end
  end

  test "complete! raises when client creds are missing" do
    assert_raises(XOauthBootstrap::ExchangeError) do
      XOauthBootstrap.complete!(account_key: "a", env_var: "X_OAUTH_ACCESS_TOKEN", code: "c",
        verifier: "v", client_id: nil, client_secret: nil)
    end
  end
end
