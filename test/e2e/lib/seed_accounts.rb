# frozen_string_literal: true

# Seed script for e2e account rotation test.
# Run via: bin/rails runner test/e2e/lib/seed_accounts.rb
#
# Creates 5 Claude accounts with OAuth configs whose access tokens
# correspond to what the mock Anthropic API server expects.
# The mock server port is passed via MOCK_API_PORT env var.

unless Rails.env.development? || Rails.env.test? || ENV["E2E_TEST"] == "true"
  raise "seed_accounts.rb should only run in development/test or with E2E_TEST=true"
end

mock_port = ENV.fetch("MOCK_API_PORT") { raise "MOCK_API_PORT env var required" }

# Token format: e2e-token-account-N matches what the e2e test configures
# in the mock Anthropic server
accounts = [
  {
    email: "account1@e2e-test.com",
    priority: 0,
    token: "e2e-token-account-1"
  },
  {
    email: "account2@e2e-test.com",
    priority: 1,
    token: "e2e-token-account-2"
  },
  {
    email: "account3@e2e-test.com",
    priority: 2,
    token: "e2e-token-account-3"
  },
  {
    email: "account4@e2e-test.com",
    priority: 3,
    token: "e2e-token-account-4"
  },
  {
    email: "account5@e2e-test.com",
    priority: 4,
    token: "e2e-token-account-5"
  }
]

# Clear existing data (order matters: rotation events reference accounts)
AccountRotationEvent.delete_all
ClaudeAccountQuotaSnapshot.delete_all
ClaudeAccount.delete_all

accounts.each_with_index do |acct, idx|
  # Far-future expiry (year 9999) so tokens never expire during tests
  expires_at_ms = 253402300800000

  oauth_config = {
    "claude_json" => {
      "oauthAccount" => acct[:email]
    },
    "credentials_json" => {
      "claudeAiOauth" => {
        "accessToken" => acct[:token],
        "refreshToken" => "refresh-#{acct[:token]}",
        "expiresAt" => expires_at_ms
      }
    }
  }

  ca = ClaudeAccount.create!(
    email: acct[:email],
    priority: acct[:priority],
    status: :active,
    is_current: idx == 0, # First account is current
    oauth_config: oauth_config,
    quota_hit_count: 0
  )

  # Create initial quota snapshots so the quotas page has data
  reset_5h = Time.current + 5.hours
  reset_7d = Time.current + 7.days

  ClaudeAccountQuotaSnapshot.create!(
    claude_account: ca,
    subscription_type: "pro",
    rate_limit_tier: "tier_4",
    utilization_5h: (idx * 0.1).round(2), # 0.0, 0.1, 0.2, 0.3, 0.4
    utilization_7d: (idx * 0.05).round(2),
    status_5h: "allowed",
    status_7d: "allowed",
    reset_5h: reset_5h,
    reset_7d: reset_7d,
    trigger: "manual_refresh"
  )

  puts "Created account #{acct[:email]} (priority: #{acct[:priority]}, current: #{idx == 0})"
end

# Write the first account's credentials to the filesystem
# so that AccountRotationService.ensure_active_account! sees it
first_account = ClaudeAccount.find_by(priority: 0)
AccountRotationService.new.write_config!(first_account)
puts "\nWrote credentials for #{first_account.email} to filesystem"
puts "Total accounts: #{ClaudeAccount.count}"
