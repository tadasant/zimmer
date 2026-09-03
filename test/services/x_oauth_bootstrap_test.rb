# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class XOauthBootstrapTest < ActiveSupport::TestCase
  include XOauthTestHelpers

  def with_env(key, value)
    original = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    original.nil? ? ENV.delete(key) : ENV[key] = original
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

  # --- redirect URI ---

  test "default_redirect_uri falls back to the registered localhost callback" do
    with_env(XOauthBootstrap::REDIRECT_URI_ENV, nil) do
      assert_equal XOauthBootstrap::DEFAULT_REDIRECT_URI, XOauthBootstrap.default_redirect_uri
    end
  end

  test "X_OAUTH_REDIRECT_URI overrides the callback on the consent URL" do
    with_env(XOauthBootstrap::REDIRECT_URI_ENV, "https://zimmer.example.com/x/callback") do
      url = XOauthBootstrap.authorize_url(
        client_id: "CID", verifier: XOauthBootstrap.generate_verifier, state: XOauthBootstrap.generate_state
      )
      params = URI.decode_www_form(URI(url).query).to_h

      assert_equal "https://zimmer.example.com/x/callback", params["redirect_uri"]
    end
  end

  # X compares the redirect_uri on the token exchange against the one on the
  # consent request, so the override has to reach both call sites or the
  # exchange fails with an opaque invalid_request.
  test "X_OAUTH_REDIRECT_URI overrides the callback on the token exchange" do
    with_env(XOauthBootstrap::REDIRECT_URI_ENV, "https://zimmer.example.com/x/callback") do
      _result, request = with_token_endpoint(code: 200, body: {
        access_token: "AT", refresh_token: "RT", expires_in: 7200, scope: XOauthCredential::OAUTH_SCOPES
      }) do
        XOauthBootstrap.complete!(
          account_key: "acct", env_var: "X_OAUTH_ACCESS_TOKEN", code: "the-code",
          verifier: "the-verifier", client_id: "CID", client_secret: "SECRET"
        )
      end

      body = URI.decode_www_form(request.body).to_h
      assert_equal "https://zimmer.example.com/x/callback", body["redirect_uri"]
    end
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

  # --- HTTP timeouts (#732) ---

  # exchange_code runs inside a web request, where an unbounded read pins a Puma
  # thread. It shares XOauthCredential's bounded POST rather than repeating the
  # Net::HTTP block, so there is one implementation to keep bounded.
  test "the code exchange bounds both connect and read at TOKEN_REQUEST_TIMEOUT" do
    with_token_endpoint(code: 200, body: { access_token: "acc", refresh_token: "ref", expires_in: 7200 }) do
      XOauthBootstrap.complete!(account_key: "a", env_var: "X_OAUTH_ACCESS_TOKEN", code: "c",
        verifier: "v", client_id: "CID", client_secret: "SEC")
    end

    assert_equal [ XOauthCredential::TOKEN_REQUEST_TIMEOUT, XOauthCredential::TOKEN_REQUEST_TIMEOUT ],
      observed_timeouts
  end

  # X rotates the refresh token on every exchange, so the rotated one must land
  # on the row.
  test "complete! persists the rotated refresh token on a brand-new row" do
    cred, = with_token_endpoint(code: 200, body: { access_token: "acc", refresh_token: "rotated", expires_in: 7200 }) do
      XOauthBootstrap.complete!(account_key: "tadasayy", env_var: "X_OAUTH_ACCESS_TOKEN", code: "c",
        verifier: "v", client_id: "CID", client_secret: "SEC")
    end

    assert_predicate cred, :persisted?
    assert_equal "rotated", cred.reload.refresh_token
    assert_equal "tadasayy", cred.account_key
    assert_equal XOauthCredential::DEFAULT_TOKEN_ENDPOINT, cred.token_endpoint
  end

  # complete! saves the identity columns before apply_token_response! writes the
  # rotating ones. Asserting the happy path cannot tell the two orderings apart —
  # apply_token_response!'s update! would insert the in-memory attributes itself —
  # so this breaks the second write and asserts the row survives it.
  test "complete! persists the identity columns before applying the token response" do
    XOauthCredential.any_instance.stubs(:apply_token_response!).raises(ActiveRecord::RecordInvalid.new(XOauthCredential.new))

    assert_raises(ActiveRecord::RecordInvalid) do
      with_token_endpoint(code: 200, body: { access_token: "acc", refresh_token: "rotated", expires_in: 7200 }) do
        XOauthBootstrap.complete!(account_key: "tadasayy", env_var: "X_OAUTH_ACCESS_TOKEN", code: "c",
          verifier: "v", client_id: "CID", client_secret: "SEC")
      end
    end

    row = XOauthCredential.find_by(access_token_env_var: "X_OAUTH_ACCESS_TOKEN")
    assert_not_nil row, "the identity columns were not persisted before the token response was applied"
    assert_equal "tadasayy", row.account_key
  end

  test "a hanging token endpoint raises Net::ReadTimeout instead of pinning the thread" do
    with_hanging_token_endpoint do |endpoint|
      with_default_token_endpoint(endpoint) do
        with_token_request_timeout(1) do
          elapsed = elapsed_seconds do
            assert_raises(Net::ReadTimeout) do
              XOauthBootstrap.complete!(account_key: "a", env_var: "X_OAUTH_ACCESS_TOKEN", code: "c",
                verifier: "v", client_id: "CID", client_secret: "SEC")
            end
          end
          assert_operator elapsed, :<, 10, "the code exchange fell back to Net::HTTP's default read timeout"
        end
      end
    end
  end
end
