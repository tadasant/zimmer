# frozen_string_literal: true

# Writes GithubRateLimit's cached state directly — an open breaker, a snapshot, a login
# GithubTokenStatus already learned — so a reporting surface can be tested against the
# state it reads without a `gh` call. Needs a real cache: swap in a MemoryStore first.
#
# Call `use_test_gh_token` in setup and `restore_gh_tokens` in teardown: GithubRateLimit
# reads GH_TOKEN and GH_TOKEN__<OWNER> from ENV, and each test should see exactly one token.
module GithubRateLimitStateHelpers
  TEST_GH_TOKEN = "ghp_rate_limit_report_test_token"

  def use_test_gh_token
    @saved_gh_env = ENV.to_h.select { |key, _| key == "GH_TOKEN" || key.start_with?("GH_TOKEN__") }
    @saved_gh_env.each_key { |key| ENV.delete(key) }
    ENV["GH_TOKEN"] = TEST_GH_TOKEN
  end

  def restore_gh_tokens
    ENV.keys.select { |key| key == "GH_TOKEN" || key.start_with?("GH_TOKEN__") }.each { |key| ENV.delete(key) }
    (@saved_gh_env || {}).each { |key, value| ENV[key] = value }
  end

  def rate_limit_credential = GithubRateLimit.credentials.first

  def open_rate_limit_breaker(resource, reset_at)
    Rails.cache.write(GithubRateLimit.exhausted_key(rate_limit_credential, resource), reset_at.to_i)
  end

  # budgets: { "core" => [remaining, limit, reset_at], ... }
  def write_rate_limit_snapshot(budgets)
    Rails.cache.write(
      GithubRateLimit.snapshot_key(rate_limit_credential),
      budgets.transform_values { |(remaining, limit, reset_at)| { "remaining" => remaining, "limit" => limit, "reset" => reset_at.to_i } }
    )
  end

  def remember_github_login(login, token: TEST_GH_TOKEN)
    Rails.cache.write(GithubTokenStatus.cache_key(token), GithubTokenStatus::Probe.new(login: login))
  end
end
