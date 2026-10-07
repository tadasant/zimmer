# frozen_string_literal: true

# Helpers for the web sign-in gate: a configuration with the gate on, Google ID
# token claims, and walking a browser through Google and the second factor.
#
# Google itself is faked at one seam, WebAuth::GoogleOauth#fetch_id_token (the
# HTTP POST to the token endpoint), so everything Zimmer does with the token,
# every claim check included, runs for real.
#
# enable_web_auth and stub_google_id_token stub with mocha, so a test file that
# uses them has to `require "mocha/minitest"` itself (see #874 and
# test/support/x_oauth_test_helpers.rb for why this file cannot).
module WebAuthTestHelpers
  GOOGLE_CLIENT_ID = "1234-test.apps.googleusercontent.com"

  def web_auth_configuration_with(**overrides)
    values = {
      WebAuth::Configuration::CLIENT_ID => GOOGLE_CLIENT_ID,
      WebAuth::Configuration::CLIENT_SECRET => "test-client-secret",
      WebAuth::Configuration::ALLOWED_DOMAINS => "tadasant.com"
    }
    overrides.each { |key, value| values[WebAuth::Configuration.const_get(key.to_s.upcase)] = value }
    WebAuth::Configuration.new(values)
  end

  # Turn the gate on for this test. Pass e.g. `second_factor: "google"` or
  # `allowed_domains: "a.com,b.com"` to vary it.
  def enable_web_auth(**overrides)
    configuration = web_auth_configuration_with(**overrides)
    WebAuth::Configuration.stubs(:current).returns(configuration)
    configuration
  end

  def google_claims(**overrides)
    {
      "iss" => "https://accounts.google.com",
      "aud" => GOOGLE_CLIENT_ID,
      "sub" => "110248495921238986420",
      "email" => "tadas@tadasant.com",
      "email_verified" => true,
      "hd" => "tadasant.com",
      "name" => "Tadas Antanavicius",
      "iat" => Time.current.to_i,
      "exp" => 1.hour.from_now.to_i
    }.merge(overrides.transform_keys(&:to_s)).compact
  end

  # An ID token as Google's token endpoint returns it. The signature segment is
  # junk on purpose: Zimmer does not check it (see WebAuth::GoogleOauth).
  def id_token_for(claims)
    segment = ->(hash) { Base64.urlsafe_encode64(hash.to_json, padding: false) }
    "#{segment.call({ "alg" => "RS256", "kid" => "test" })}.#{segment.call(claims)}.c2lnbmF0dXJl"
  end

  def stub_google_id_token(claims)
    WebAuth::GoogleOauth.any_instance.stubs(:fetch_id_token).returns(id_token_for(claims))
  end

  # POST /auth/google, follow Google back to the callback with the right state.
  def sign_in_with_google(claims = google_claims)
    post google_sign_in_path
    assert_response :redirect
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    stub_google_id_token(claims)
    get google_sign_in_callback_path, params: { code: "4/test-authorization-code", state: state }
  end

  def current_totp_code(secret, at: Time.current)
    WebAuth::Totp.code_at(secret, at)
  end

  # Google, then the authenticator setup page, as a first-time user.
  # @return [WebIdentity]
  def sign_in_and_enroll(claims = google_claims)
    sign_in_with_google(claims)
    assert_redirected_to second_factor_setup_path
    get second_factor_setup_path
    identity = WebIdentity.find_by!(google_sub: claims["sub"])
    post second_factor_setup_path, params: { code: current_totp_code(identity.reload.totp_pending_secret) }
    assert_response :success
    identity.reload
  end
end
