# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class WebAuth::ConfigurationTest < ActiveSupport::TestCase
  include WebAuthTestHelpers

  teardown { WebAuth::Configuration.reset! }

  test "off when no client ID is set, which is every deployment that has not opted in" do
    configuration = WebAuth::Configuration.new({})

    refute_predicate configuration, :enabled?
    assert_empty configuration.problems
  end

  test "on and usable with a client ID, a secret and a domain" do
    configuration = web_auth_configuration_with

    assert_predicate configuration, :enabled?
    assert_predicate configuration, :usable?
    assert_equal [ "tadasant.com" ], configuration.allowed_domains
  end

  test "a client ID with the rest missing is on but unusable, and says what is missing" do
    configuration = web_auth_configuration_with(client_secret: nil, allowed_domains: " ")

    assert_predicate configuration, :enabled?
    refute_predicate configuration, :usable?
    assert_equal [ "ZIMMER_WEB_AUTH_GOOGLE_CLIENT_SECRET is not set", "ZIMMER_WEB_AUTH_ALLOWED_DOMAINS names no domain" ],
      configuration.problems
  end

  test "allowed domains are a lowercased list, commas or spaces" do
    configuration = web_auth_configuration_with(allowed_domains: "Tadasant.com, @example.org  other.net")

    assert_equal %w[tadasant.com example.org other.net], configuration.allowed_domains
    assert configuration.domain_allowed?("TADASANT.COM")
    refute configuration.domain_allowed?("gmail.com")
    refute configuration.domain_allowed?(nil)
  end

  test "defaults: TOTP, a 90-day rolling session, a 365-day trusted device" do
    configuration = web_auth_configuration_with

    assert_predicate configuration, :totp_required?
    assert_equal 90.days, configuration.session_ttl
    assert_equal 365.days, configuration.trusted_device_ttl
  end

  test "the durations and the second-factor mode are configurable, and nonsense falls back" do
    configuration = web_auth_configuration_with(session_days: "30", trusted_device_days: "-4", second_factor: "google")

    assert_equal 30.days, configuration.session_ttl
    assert_equal 365.days, configuration.trusted_device_ttl
    refute_predicate configuration, :totp_required?

    assert_includes web_auth_configuration_with(second_factor: "sms").problems,
      "ZIMMER_WEB_AUTH_SECOND_FACTOR must be one of totp, google"
  end

  test "the second-factor reset instant parses ISO 8601 and ignores anything else" do
    assert_equal Time.utc(2026, 10, 7, 12), web_auth_configuration_with(second_factor_reset_before: "2026-10-07T12:00:00Z").second_factor_reset_before
    assert_nil web_auth_configuration_with(second_factor_reset_before: "yesterday").second_factor_reset_before
  end

  test "the redirect URI is the deployment's base URL plus the callback path" do
    AppUrl.stubs(:base_url).returns("https://zimmer.example.com")

    assert_equal "https://zimmer.example.com/auth/google/callback", web_auth_configuration_with.redirect_uri
  end

  test "current reads through the secret-provider chain" do
    chain = mock("chain")
    chain.stubs(:get).returns(nil)
    chain.stubs(:get).with("ZIMMER_WEB_AUTH_GOOGLE_CLIENT_ID").returns("from-the-store")
    SecretProviders.stubs(:chain).returns(chain)

    assert_equal "from-the-store", WebAuth::Configuration.current.client_id
  end

  test "an unreachable store keeps the last answer, and with no last answer raises Unavailable" do
    failing = mock("chain")
    failing.stubs(:get).raises(ParameterStore::StoreError, "store down")
    SecretProviders.stubs(:chain).returns(failing)

    assert_raises(WebAuth::Configuration::Unavailable) { WebAuth::Configuration.current }

    working = mock("chain")
    working.stubs(:get).returns(nil)
    working.stubs(:get).with("ZIMMER_WEB_AUTH_GOOGLE_CLIENT_ID").returns("cid")
    SecretProviders.stubs(:chain).returns(working)
    assert_equal "cid", WebAuth::Configuration.current.client_id

    # Past the cache TTL, so the next read asks the (failing) store again.
    SecretProviders.stubs(:chain).returns(failing)
    later = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WebAuth::Configuration::CACHE_TTL.to_i + 1
    Process.stubs(:clock_gettime).returns(later)
    assert_equal "cid", WebAuth::Configuration.current.client_id
  end

  test "a mistyped second-factor mode still requires TOTP, and a bad reset instant is a problem" do
    configuration = web_auth_configuration_with(second_factor: "topt", second_factor_reset_before: "yesterday")

    assert_predicate configuration, :totp_required?
    refute_predicate configuration, :usable?
    assert_includes configuration.problems, "ZIMMER_WEB_AUTH_SECOND_FACTOR_RESET_BEFORE is not an ISO 8601 time"
  end

  test "a process that boots during a store outage uses the last answer in Rails.cache, minus the secret" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    working = mock("chain")
    working.stubs(:get).returns(nil)
    working.stubs(:get).with("ZIMMER_WEB_AUTH_GOOGLE_CLIENT_ID").returns("cid")
    working.stubs(:get).with("ZIMMER_WEB_AUTH_GOOGLE_CLIENT_SECRET").returns("secret")
    working.stubs(:get).with("ZIMMER_WEB_AUTH_ALLOWED_DOMAINS").returns("tadasant.com")
    SecretProviders.stubs(:chain).returns(working)
    WebAuth::Configuration.current
    WebAuth::Configuration.reset!

    failing = mock("chain")
    failing.stubs(:get).raises(ParameterStore::StoreError, "store down")
    SecretProviders.stubs(:chain).returns(failing)
    configuration = WebAuth::Configuration.current

    assert_predicate configuration, :enabled?
    assert_nil configuration.client_secret
    assert_equal [ "tadasant.com" ], configuration.allowed_domains
    refute_predicate configuration, :usable?
    assert_match "not answering", configuration.problems.first
  end
end
