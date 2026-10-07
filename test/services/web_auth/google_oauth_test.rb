# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The claim checks, run for real against claims shaped like Google's. The HTTP
# exchange is the only part faked (WebAuthTestHelpers#stub_google_id_token).
class WebAuth::GoogleOauthTest < ActiveSupport::TestCase
  include WebAuthTestHelpers

  setup do
    @configuration = web_auth_configuration_with
    @google = WebAuth::GoogleOauth.new(@configuration)
  end

  test "an allowed Workspace account with a verified email is let in" do
    identity = @google.verify(google_claims)

    assert_equal "110248495921238986420", identity.sub
    assert_equal "tadas@tadasant.com", identity.email
    assert_equal "tadasant.com", identity.hosted_domain
  end

  test "an account from another Workspace is refused, by its hd claim" do
    error = assert_raises(WebAuth::GoogleOauth::Rejected) { @google.verify(google_claims(hd: "evil.example", email: "x@evil.example")) }
    assert_match "belongs to evil.example", error.message
  end

  test "a personal account is refused even when its email is on the allowed domain" do
    # The case the hd check exists for: a gmail account can carry an address on
    # someone else's domain, verified, with no hd claim at all.
    error = assert_raises(WebAuth::GoogleOauth::Rejected) { @google.verify(google_claims(hd: nil, email: "tadas@tadasant.com")) }
    assert_match "personal Google account", error.message
  end

  test "an unverified email is refused" do
    [ false, nil, "true" ].each do |verified|
      error = assert_raises(WebAuth::GoogleOauth::Rejected) { @google.verify(google_claims(email_verified: verified)) }
      assert_match "not verified", error.message
    end
  end

  test "a token for another client, another issuer, or past its expiry is refused" do
    assert_raises(WebAuth::GoogleOauth::Rejected) { @google.verify(google_claims(aud: "someone-else.apps.googleusercontent.com")) }
    assert_raises(WebAuth::GoogleOauth::Rejected) { @google.verify(google_claims(iss: "https://accounts.evil.example")) }
    assert_raises(WebAuth::GoogleOauth::Rejected) { @google.verify(google_claims(exp: 1.hour.ago.to_i)) }
    assert_raises(WebAuth::GoogleOauth::Rejected) { @google.verify(google_claims(sub: "")) }
  end

  test "complete decodes the token Google's endpoint returned and verifies it" do
    stub_google_id_token(google_claims)

    assert_equal "tadas@tadasant.com", @google.complete(code: "c", code_verifier: "v").email
  end

  test "a malformed token is an exchange failure, not a crash" do
    WebAuth::GoogleOauth.any_instance.stubs(:fetch_id_token).returns("not-a-jwt")

    assert_raises(WebAuth::GoogleOauth::ExchangeFailed) { @google.complete(code: "c", code_verifier: "v") }
  end

  test "the consent URL carries PKCE, the state, and the hd hint when there is one domain" do
    url = URI(@google.authorization_url(state: "st", code_verifier: "verifier"))
    query = Rack::Utils.parse_query(url.query)

    assert_equal "accounts.google.com", url.host
    assert_equal GOOGLE_CLIENT_ID, query["client_id"]
    assert_equal "st", query["state"]
    assert_equal "S256", query["code_challenge_method"]
    assert_equal WebAuth::GoogleOauth.code_challenge("verifier"), query["code_challenge"]
    assert_equal "openid email profile", query["scope"]
    assert_equal "tadasant.com", query["hd"]

    two_domains = WebAuth::GoogleOauth.new(web_auth_configuration_with(allowed_domains: "a.com,b.com"))
    assert_nil Rack::Utils.parse_query(URI(two_domains.authorization_url(state: "s", code_verifier: "v")).query)["hd"]
  end
end
