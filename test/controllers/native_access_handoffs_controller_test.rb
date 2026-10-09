# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# GET /native/access-handoff: the iOS app's edge sign-in, which returns the
# Cloudflare Access assertion to the app's private-use scheme once it checks out.
class NativeAccessHandoffsControllerTest < ActionDispatch::IntegrationTest
  TEAM = "team.cloudflareaccess.test"
  AUD = "native-app-aud-tag"
  STATE = "s" * 32
  ENV_KEYS = [ NativeAccessAssertion::TEAM_DOMAIN_KEY, NativeAccessAssertion::AUD_KEY ].freeze

  setup do
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV[NativeAccessAssertion::TEAM_DOMAIN_KEY] = TEAM
    ENV[NativeAccessAssertion::AUD_KEY] = AUD
    @key = OpenSSL::PKey::RSA.generate(2048)
    @jwk = JWT::JWK.new(@key, kid: "k1")
    jwks = { "keys" => [ @jwk.export ] }
    @fetches = 0
    NativeAccessAssertion.jwks_fetcher = ->(team) { @fetches += 1; @fetched_team = team; jwks }
    Rails.cache.clear
  end

  teardown do
    NativeAccessAssertion.jwks_fetcher = nil
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def assertion(claims: {}, key: @key, kid: "k1")
    payload = { "iss" => "https://#{TEAM}", "aud" => [ AUD ], "email" => "tadas@tadasant.com",
      "iat" => Time.now.to_i, "exp" => 30.days.from_now.to_i }.merge(claims)
    JWT.encode(payload, key, "RS256", { kid: kid })
  end

  def handoff(token, state: STATE)
    headers = token ? { "Cf-Access-Jwt-Assertion" => token } : {}
    get "/native/access-handoff", params: { state: state }, headers: headers
  end

  test "a valid assertion redirects to the app's hard-coded callback: state in the query, token in the fragment" do
    token = assertion
    handoff(token)

    assert_response :found
    assert_equal "com.tadasant.zimmer:/access/callback?state=#{STATE}#cf_access_token=#{token}", response.location
    uri = URI.parse(response.location)
    assert_equal({ "state" => STATE }, URI.decode_www_form(uri.query).to_h)
    assert_equal token, URI.decode_www_form(uri.fragment).to_h["cf_access_token"]
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_equal TEAM, @fetched_team
  end

  test "the callback is never taken from a parameter" do
    get "/native/access-handoff", params: { state: STATE, redirect_uri: "https://evil.test/", callback: "evil:/x" },
      headers: { "Cf-Access-Jwt-Assertion" => assertion }

    assert response.location.start_with?("com.tadasant.zimmer:/access/callback?")
  end

  test "no assertion header is a 403" do
    handoff(nil)

    assert_response :forbidden
    assert_nil response.location
  end

  test "an assertion from another issuer is a 403" do
    handoff(assertion(claims: { "iss" => "https://other.cloudflareaccess.com" }))

    assert_response :forbidden
  end

  test "an expired assertion is a 403" do
    handoff(assertion(claims: { "exp" => 2.hours.ago.to_i, "iat" => 3.hours.ago.to_i }))

    assert_response :forbidden
  end

  test "an assertion signed by a key the team did not publish is a 403" do
    handoff(assertion(key: OpenSSL::PKey::RSA.generate(2048)))

    assert_response :forbidden
  end

  test "an unsigned assertion is a 403" do
    handoff(JWT.encode({ "iss" => "https://#{TEAM}", "exp" => 1.hour.from_now.to_i }, nil, "none"))

    assert_response :forbidden
  end

  test "an assertion for another Access application of the team is a 403" do
    handoff(assertion(claims: { "aud" => [ "another-app" ] }))

    assert_response :forbidden
  end

  test "with no audience configured, every assertion is refused" do
    ENV.delete(NativeAccessAssertion::AUD_KEY)
    handoff(assertion)

    assert_response :forbidden
    assert_equal 0, @fetches, "nothing is fetched for a handoff that cannot pass"
  end

  test "a bad state is a 400, checked before the assertion" do
    [ "short", "x" * 257, "has space#{'x' * 20}", "slash/#{'x' * 20}" ].each do |state|
      handoff(assertion, state: state)
      assert_response :bad_request, "state #{state.inspect}"
    end
    get "/native/access-handoff", headers: { "Cf-Access-Jwt-Assertion" => assertion }
    assert_response :bad_request
  end

  test "the JWKS is cached, and fetched again for a key it does not hold" do
    # The test environment's cache is a null store; production's is Redis.
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    handoff(assertion)
    handoff(assertion)
    assert_equal 1, @fetches

    rotated = OpenSSL::PKey::RSA.generate(2048)
    rotated_jwk = JWT::JWK.new(rotated, kid: "k2")
    NativeAccessAssertion.jwks_fetcher = ->(_team) { @fetches += 1; { "keys" => [ @jwk.export, rotated_jwk.export ] } }
    handoff(assertion(key: rotated, kid: "k2"))

    assert_response :found
    assert_equal 2, @fetches
  end

  test "the team domain defaults to Tadas's Access team" do
    ENV.delete(NativeAccessAssertion::TEAM_DOMAIN_KEY)

    assert_equal "tadasant.cloudflareaccess.com", NativeAccessAssertion.new.team_domain
  end

  test "it needs no web sign-in and does not depend on the request host" do
    host! "zimmer.tadasant.com"
    handoff(assertion)

    assert_response :found
  end
end
