# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class GithubTokenStatusTest < ActiveSupport::TestCase
  NOW = Time.zone.parse("2026-10-21 12:00:00 UTC")

  MAP = {
    "ZIMMER_GITHUB_CREDENTIAL_ROUTING" => "1",
    "GH_TOKEN" => "github_pat_tadasant",
    "GH_TOKEN__PULSEMCP" => "github_pat_pulsemcp",
    "ZIMMER_GITHUB_DEFAULT_OWNER" => "tadasant"
  }.freeze

  setup { Rails.cache.clear }

  test "names each token's account and expiry, and flags one expiring within 30 days" do
    GithubTokenStatus.stubs(:fetch).with("github_pat_tadasant")
      .returns(GithubTokenStatus::Probe.new(login: "tadasant", expires_at: NOW + 200.days))
    GithubTokenStatus.stubs(:fetch).with("github_pat_pulsemcp")
      .returns(GithubTokenStatus::Probe.new(login: "tadasant", expires_at: NOW + 12.days))

    line = GithubTokenStatus.summary(env: MAP, now: NOW)

    assert_includes line, "Default owner tadasant."
    assert_includes line, "GH_TOKEN (tadasant): tadasant, expires 2027-05-09"
    assert_includes line, "GH_TOKEN__PULSEMCP (pulsemcp): tadasant, EXPIRES IN 12 DAYS (2026-11-02) — renew it"
    refute_includes line, "github_pat_"
  end

  test "a token GitHub refuses is reported, not raised" do
    GithubTokenStatus.stubs(:fetch).returns(GithubTokenStatus::Probe.new(error: "GitHub answered HTTP 401"))

    assert_includes GithubTokenStatus.summary(env: MAP, now: NOW), "GH_TOKEN (tadasant): could not verify — GitHub answered HTTP 401"
  end

  test "probes are cached, so the two-minute refresh is not two-minute GitHub traffic" do
    GithubTokenStatus.expects(:fetch).twice.returns(GithubTokenStatus::Probe.new(login: "x", expires_at: nil))
    with_memory_cache do
      2.times { GithubTokenStatus.summary(env: MAP, now: NOW) }
    end
  end

  test "before routing is on, it says the stored login is in use" do
    assert_match(/No GitHub token map is seeded/, GithubTokenStatus.summary(env: {}, now: NOW))
  end

  test "fetch reads the login and the expiration header" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["github-authentication-token-expiration"] = "2026-12-01 00:00:00 UTC"
    response.stubs(:body).returns({ "login" => "tadasant" }.to_json)
    Net::HTTP.stubs(:start).returns(response)

    probe = GithubTokenStatus.fetch("github_pat_x")

    assert_equal "tadasant", probe.login
    assert_equal Time.zone.parse("2026-12-01 00:00:00 UTC"), probe.expires_at
  end

  private

  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end
end
