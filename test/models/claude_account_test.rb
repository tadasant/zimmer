# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class ClaudeAccountTest < ActiveSupport::TestCase
  test "validates email presence" do
    account = ClaudeAccount.new(email: nil)
    assert_not account.valid?
    assert_includes account.errors[:email], "can't be blank"
  end

  test "validates email uniqueness" do
    existing = claude_accounts(:primary)
    account = ClaudeAccount.new(email: existing.email)
    assert_not account.valid?
    assert_includes account.errors[:email], "has already been taken"
  end

  test "email uniqueness is scoped to runtime: same email + same runtime is invalid" do
    existing = claude_accounts(:primary) # runtime: claude_code
    duplicate = ClaudeAccount.new(email: existing.email, runtime: existing.runtime)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:email], "has already been taken"
  end

  test "email uniqueness is scoped to runtime: same email + different runtime is valid" do
    existing = claude_accounts(:primary) # runtime: claude_code
    other_runtime = ClaudeAccount.new(email: existing.email, runtime: CodexAuthProvider::RUNTIME)
    assert other_runtime.valid?, "expected a #{CodexAuthProvider::RUNTIME} account to coexist with a claude_code account of the same email, got: #{other_runtime.errors.full_messages.to_sentence}"
  end

  test "DB enforces composite uniqueness on [email, runtime]" do
    existing = claude_accounts(:primary) # runtime: claude_code

    # Same email + different runtime persists fine (per-runtime pools).
    assert_nothing_raised do
      ClaudeAccount.create!(email: existing.email, runtime: CodexAuthProvider::RUNTIME)
    end

    # Same email + same runtime is rejected at the database level even when the
    # model validation is bypassed (save(validate: false) still hits the index).
    duplicate = existing.dup
    assert_raises(ActiveRecord::RecordNotUnique) do
      duplicate.save!(validate: false)
    end
  end

  test "status enum works" do
    account = claude_accounts(:primary)
    assert account.active?

    exceeded = claude_accounts(:exceeded)
    assert exceeded.quota_exceeded?
  end

  test "current_account returns the is_current account from DB" do
    current = ClaudeAccount.current_account
    assert_equal claude_accounts(:primary), current
    assert current.is_current?
  end

  test "current_account returns nil when no account is marked current" do
    ClaudeAccount.update_all(is_current: false)
    assert_nil ClaudeAccount.current_account
  end

  test "current_account is DB-authoritative and does not read filesystem" do
    # Even if the filesystem has a different account, DB wins.
    # This prevents cross-container races where the web and worker
    # have different ~/.claude.json files.
    secondary = claude_accounts(:secondary)
    secondary.mark_current!

    current = ClaudeAccount.current_account
    assert_equal secondary, current
    assert_not claude_accounts(:primary).reload.is_current?
  end

  test "available scope returns active accounts with config ordered by priority" do
    available = ClaudeAccount.available
    assert available.all?(&:active?)
    assert available.all? { |a| a.oauth_config.present? && a.oauth_config.is_a?(Hash) && a.oauth_config.keys.any? }
    priorities = available.map(&:priority)
    assert_equal priorities.sort, priorities
  end

  test "available scope excludes unconfigured accounts" do
    unconfigured = claude_accounts(:unconfigured)
    assert_not ClaudeAccount.available.include?(unconfigured)
  end

  test "has_valid_config? returns true for accounts with oauth_config" do
    assert claude_accounts(:primary).has_valid_config?
    assert_not claude_accounts(:unconfigured).has_valid_config?
  end

  test "latest_snapshot returns most recent snapshot" do
    account = claude_accounts(:primary)
    snapshot = claude_account_quota_snapshots(:primary_recent)
    assert_equal snapshot, account.latest_snapshot
  end

  test "mark_quota_exceeded! updates status and increments hit count" do
    account = claude_accounts(:primary)
    original_count = account.quota_hit_count
    account.mark_quota_exceeded!
    account.reload

    assert account.quota_exceeded?
    assert_equal original_count + 1, account.quota_hit_count
  end

  test "mark_current! sets is_current and clears others" do
    secondary = claude_accounts(:secondary)
    secondary.mark_current!

    assert secondary.reload.is_current?
    assert_not claude_accounts(:primary).reload.is_current?
    assert_not_nil secondary.last_rotated_to_at
  end

  test "destroying account destroys snapshots" do
    account = claude_accounts(:primary)
    snapshot_count = account.quota_snapshots.count
    assert snapshot_count > 0

    account.destroy
    assert_equal 0, ClaudeAccountQuotaSnapshot.where(claude_account_id: account.id).count
  end

  # Token management tests

  test "token_expires_at parses milliseconds epoch from oauth_config" do
    account = claude_accounts(:primary)
    expires_at = account.token_expires_at
    assert_instance_of Time, expires_at
    # Fixture has expiresAt: 9999999999999 (milliseconds)
    assert_equal Time.at(9999999999999 / 1000.0), expires_at
  end

  test "token_expires_at returns nil when no credentials" do
    account = claude_accounts(:unconfigured)
    assert_nil account.token_expires_at
  end

  test "token_expired? returns false for far-future expiry" do
    account = claude_accounts(:primary)
    assert_not account.token_expired?
  end

  test "token_expired? returns true for past expiry" do
    account = claude_accounts(:expired_token)
    assert account.token_expired?
  end

  test "token_expiring_soon? returns false for far-future expiry" do
    account = claude_accounts(:primary)
    assert_not account.token_expiring_soon?
  end

  test "token_expiring_soon? returns true for near-future expiry" do
    account = claude_accounts(:primary)
    config = account.oauth_config.deep_dup
    config["credentials_json"]["claudeAiOauth"]["expiresAt"] = ((Time.current + 5.minutes).to_f * 1000).to_i
    account.update!(oauth_config: config)

    assert account.token_expiring_soon?(15.minutes)
  end

  test "can_refresh_token? returns true when refresh token present" do
    account = claude_accounts(:primary)
    assert account.can_refresh_token?
  end

  test "can_refresh_token? returns false when no refresh token" do
    account = claude_accounts(:unconfigured)
    assert_not account.can_refresh_token?
  end

  test "refresh_token! updates tokens on success" do
    account = claude_accounts(:expired_token)

    successful_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_response.stubs(:code).returns("200")
    successful_response.stubs(:body).returns({
      access_token: "new-access-token",
      refresh_token: "new-refresh-token",
      expires_in: 3600
    }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(successful_response)
    assert account.refresh_token!

    account.reload
    assert_equal "new-access-token", account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    assert_equal "new-refresh-token", account.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
    assert_not account.token_expired?
  end

  test "refresh_token! returns false on failure" do
    account = claude_accounts(:expired_token)
    original_token = account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")

    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({ error: "server_error" }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)
    assert_not account.refresh_token!

    account.reload
    assert_equal original_token, account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
  end

  test "refresh_token! marks needs_reauth on permanent failure" do
    account = claude_accounts(:expired_token)

    failed_response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    failed_response.stubs(:code).returns("401")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)
    assert_not account.refresh_token!

    account.reload
    assert account.needs_reauth?
  end

  test "refresh_token! uses filesystem refresh token when CLI rotated it behind AO" do
    # Simulates the divergence case from issue #2964: CLI rotated the refresh token
    # on disk (via Anthropic's OAuth rotation during a session) but AO's DB still
    # holds the original stale token. Without the sync, the OAuth call would use
    # the stale token and fail with invalid_grant.
    tmpdir = Dir.mktmpdir
    original_cred_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    original_json_path = ClaudeAuthProvider::CLAUDE_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(tmpdir, ".credentials.json"))
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(tmpdir, "claude.json"))

    begin
      account = claude_accounts(:primary) # is_current: true, DB refreshToken: test_refresh_token_1
      FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))

      # Filesystem has a newer refresh token (CLI-rotated)
      fs_refresh_token = "cli-rotated-refresh-token"
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({
        "oauthAccount" => { "emailAddress" => "tadas@tadasant.com" }
      }))
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate({
        "claudeAiOauth" => {
          "accessToken" => "cli-rotated-access-token",
          "refreshToken" => fs_refresh_token,
          "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
        }
      }))
      # Owner marker names this account, so refresh_token!'s pre-sync recognizes
      # the CLI-rotated tokens on disk as belonging to it.
      ClaudeAccount.write_credentials_owner_marker!(account.email)

      # Capture the refresh_token that gets sent to the OAuth endpoint
      sent_refresh_token = nil
      Net::HTTP.any_instance.stubs(:request).with do |req|
        sent_refresh_token = URI.decode_www_form(req.body).to_h["refresh_token"]
        true
      end.returns(begin
        response = Net::HTTPSuccess.new("1.1", "200", "OK")
        response.stubs(:code).returns("200")
        response.stubs(:body).returns({
          access_token: "new-access",
          refresh_token: "new-refresh",
          expires_in: 3600
        }.to_json)
        response
      end)

      assert account.refresh_token!

      # The OAuth call used the filesystem's (newer) refresh token, not the stale DB one
      assert_equal fs_refresh_token, sent_refresh_token,
        "refresh_token! should use filesystem refresh token, not stale DB token"
    ensure
      FileUtils.rm_rf(tmpdir)
      ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
      ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original_cred_path)
      ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
      ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, original_json_path)
    end
  end

  test "refresh_token! does not sync from filesystem when account is not current" do
    # Non-current accounts cannot have filesystem divergence because ~/.credentials.json
    # only ever holds the current account's tokens. Syncing for them would corrupt
    # their DB tokens with the current account's (different) tokens.
    tmpdir = Dir.mktmpdir
    original_cred_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    original_json_path = ClaudeAuthProvider::CLAUDE_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(tmpdir, ".credentials.json"))
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(tmpdir, "claude.json"))

    begin
      account = claude_accounts(:secondary) # is_current: false, DB refreshToken: test_refresh_token_2
      FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))

      # Filesystem has a different account's tokens (the current account's)
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({
        "oauthAccount" => { "emailAddress" => "tadas@tadasant.com" }
      }))
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate({
        "claudeAiOauth" => {
          "accessToken" => "different-account-access",
          "refreshToken" => "different-account-refresh",
          "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
        }
      }))

      sent_refresh_token = nil
      Net::HTTP.any_instance.stubs(:request).with do |req|
        sent_refresh_token = URI.decode_www_form(req.body).to_h["refresh_token"]
        true
      end.returns(begin
        response = Net::HTTPSuccess.new("1.1", "200", "OK")
        response.stubs(:code).returns("200")
        response.stubs(:body).returns({
          access_token: "new-access",
          refresh_token: "new-refresh",
          expires_in: 3600
        }.to_json)
        response
      end)

      assert account.refresh_token!

      # Must use the DB's token, not the filesystem's (which belongs to a different account)
      assert_equal "test_refresh_token_2", sent_refresh_token,
        "non-current account must not sync from filesystem (wrong identity)"
    ensure
      FileUtils.rm_rf(tmpdir)
      ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
      ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original_cred_path)
      ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
      ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, original_json_path)
    end
  end

  test "refresh_token! writes to filesystem when account is current" do
    tmpdir = Dir.mktmpdir
    original_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(tmpdir, ".credentials.json"))

    begin
      account = claude_accounts(:primary) # is_current: true
      FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))

      successful_response = Net::HTTPSuccess.new("1.1", "200", "OK")
      successful_response.stubs(:code).returns("200")
      successful_response.stubs(:body).returns({
        access_token: "fs-written-token",
        refresh_token: "fs-written-refresh",
        expires_in: 3600
      }.to_json)

      Net::HTTP.any_instance.stubs(:request).returns(successful_response)
      account.refresh_token!

      assert File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH)
      fs_data = JSON.parse(File.read(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))
      assert_equal "fs-written-token", fs_data.dig("claudeAiOauth", "accessToken")
    ensure
      FileUtils.rm_rf(tmpdir)
      ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
      ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original_path)
    end
  end

  test "sync_tokens_from_filesystem! updates DB from filesystem" do
    tmpdir = Dir.mktmpdir
    original_cred_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    original_json_path = ClaudeAuthProvider::CLAUDE_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(tmpdir, ".credentials.json"))
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(tmpdir, "claude.json"))

    begin
      account = claude_accounts(:primary) # is_current: true
      FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))

      fs_credentials = {
        "claudeAiOauth" => {
          "accessToken" => "synced-from-filesystem",
          "refreshToken" => "synced-refresh",
          "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
        }
      }
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate(fs_credentials))

      # Stamp the shared owner marker to this account so the ownership gate passes
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({ "oauthAccount" => "tadas@tadasant.com" }))
      ClaudeAccount.write_credentials_owner_marker!(account.email)

      account.sync_tokens_from_filesystem!
      account.reload

      assert_equal "synced-from-filesystem", account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
      assert_equal "synced-refresh", account.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
    ensure
      FileUtils.rm_rf(tmpdir)
      ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
      ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original_cred_path)
      ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
      ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, original_json_path)
    end
  end

  test "sync_tokens_from_filesystem! syncs non-current account when it owns the credentials marker" do
    # Sync is gated on the shared owner marker, not on is_current?. This lets
    # manual switches and ensure_active_account!'s DB-wins branch capture the
    # outgoing/non-current account's CLI-rotated tokens before write_config!
    # overwrites them. Without this, switching away from an account permanently
    # loses any refresh_token rotation the CLI performed while it was current.
    tmpdir = Dir.mktmpdir
    original_cred_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    original_json_path = ClaudeAuthProvider::CLAUDE_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(tmpdir, ".credentials.json"))
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(tmpdir, "claude.json"))

    begin
      account = claude_accounts(:secondary) # is_current: false, email: sam@tadasant.com
      assert_not account.is_current?
      FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))

      fs_credentials = {
        "claudeAiOauth" => {
          "accessToken" => "non-current-synced-token",
          "refreshToken" => "non-current-synced-refresh",
          "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
        }
      }
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate(fs_credentials))
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({ "oauthAccount" => "sam@tadasant.com" }))
      ClaudeAccount.write_credentials_owner_marker!(account.email)

      account.sync_tokens_from_filesystem!
      account.reload

      assert_equal "non-current-synced-token", account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
      assert_equal "non-current-synced-refresh", account.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
    ensure
      FileUtils.rm_rf(tmpdir)
      ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
      ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original_cred_path)
      ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
      ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, original_json_path)
    end
  end

  test "sync_tokens_from_filesystem! is no-op when ~/.claude.json is missing" do
    # Without the identity file we can't tell whose credentials are on disk,
    # so the safe default is to leave the DB copy alone.
    tmpdir = Dir.mktmpdir
    original_cred_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    original_json_path = ClaudeAuthProvider::CLAUDE_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(tmpdir, ".credentials.json"))
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(tmpdir, "claude.json"))

    begin
      account = claude_accounts(:primary)
      original_config = account.oauth_config.deep_dup
      FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))

      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate({
        "claudeAiOauth" => {
          "accessToken" => "should-not-be-synced",
          "refreshToken" => "should-not-be-synced",
          "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
        }
      }))
      # Intentionally do NOT write CLAUDE_JSON_PATH

      account.sync_tokens_from_filesystem!
      account.reload

      assert_equal original_config, account.oauth_config
    ensure
      FileUtils.rm_rf(tmpdir)
      ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
      ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original_cred_path)
      ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
      ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, original_json_path)
    end
  end

  test "sync_tokens_from_filesystem! skips sync when filesystem identity does not match account" do
    tmpdir = Dir.mktmpdir
    original_cred_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    original_json_path = ClaudeAuthProvider::CLAUDE_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(tmpdir, ".credentials.json"))
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(tmpdir, "claude.json"))

    begin
      account = claude_accounts(:primary) # is_current: true, oauthAccount: tadas@tadasant.com
      original_token = account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
      FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))

      # Write credentials from a DIFFERENT account to the filesystem
      fs_credentials = {
        "claudeAiOauth" => {
          "accessToken" => "wrong-account-token",
          "refreshToken" => "wrong-account-refresh",
          "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
        }
      }
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate(fs_credentials))

      # Write claude.json with a different account's identity
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({ "oauthAccount" => "sam@tadasant.com" }))

      account.sync_tokens_from_filesystem!
      account.reload

      # Should NOT have synced — identity mismatch
      assert_equal original_token, account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    ensure
      FileUtils.rm_rf(tmpdir)
      ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
      ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original_cred_path)
      ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
      ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, original_json_path)
    end
  end

  test "sync_tokens_from_filesystem! syncs when filesystem identity matches account" do
    tmpdir = Dir.mktmpdir
    original_cred_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    original_json_path = ClaudeAuthProvider::CLAUDE_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(tmpdir, ".credentials.json"))
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(tmpdir, "claude.json"))

    begin
      account = claude_accounts(:primary) # is_current: true, oauthAccount: tadas@tadasant.com
      FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))

      fs_credentials = {
        "claudeAiOauth" => {
          "accessToken" => "matching-account-token",
          "refreshToken" => "matching-account-refresh",
          "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
        }
      }
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate(fs_credentials))

      # Owner marker names the SAME account
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({ "oauthAccount" => "tadas@tadasant.com" }))
      ClaudeAccount.write_credentials_owner_marker!(account.email)

      account.sync_tokens_from_filesystem!
      account.reload

      # Should sync — marker names this account
      assert_equal "matching-account-token", account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    ensure
      FileUtils.rm_rf(tmpdir)
      ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
      ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original_cred_path)
      ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
      ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, original_json_path)
    end
  end

  test "sync_tokens_from_filesystem! skips sync when filesystem refreshToken is blank" do
    tmpdir = Dir.mktmpdir
    original_cred_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    original_json_path = ClaudeAuthProvider::CLAUDE_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(tmpdir, ".credentials.json"))
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(tmpdir, "claude.json"))

    begin
      account = claude_accounts(:primary) # is_current: true, oauthAccount: tadas@tadasant.com
      original_access = account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
      original_refresh = account.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
      FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))

      # Filesystem credentials have a clobbered (blank) refreshToken — the
      # exact corruption pattern observed in the prod incident on 2026-04-30.
      fs_credentials = {
        "claudeAiOauth" => {
          "accessToken" => "fs-access-token",
          "refreshToken" => "",
          "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
        }
      }
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate(fs_credentials))
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({ "oauthAccount" => "tadas@tadasant.com" }))

      account.sync_tokens_from_filesystem!
      account.reload

      # DB must still hold the previously-good tokens
      assert_equal original_access, account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
      assert_equal original_refresh, account.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
    ensure
      FileUtils.rm_rf(tmpdir)
      ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
      ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original_cred_path)
      ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
      ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, original_json_path)
    end
  end

  test "sync_tokens_from_filesystem! skips sync when filesystem accessToken is blank" do
    tmpdir = Dir.mktmpdir
    original_cred_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    original_json_path = ClaudeAuthProvider::CLAUDE_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(tmpdir, ".credentials.json"))
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(tmpdir, "claude.json"))

    begin
      account = claude_accounts(:primary)
      original_access = account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
      original_refresh = account.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
      FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))

      fs_credentials = {
        "claudeAiOauth" => {
          "accessToken" => "",
          "refreshToken" => "fs-refresh-token",
          "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
        }
      }
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate(fs_credentials))
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({ "oauthAccount" => "tadas@tadasant.com" }))

      account.sync_tokens_from_filesystem!
      account.reload

      assert_equal original_access, account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
      assert_equal original_refresh, account.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
    ensure
      FileUtils.rm_rf(tmpdir)
      ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
      ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original_cred_path)
      ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
      ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, original_json_path)
    end
  end

  test "destroy deletes rotation events where account is rotated_to" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    event = AccountRotationEvent.create!(
      rotated_from: primary,
      rotated_to: secondary,
      reason: "quota_exceeded",
      source: "automatic"
    )

    secondary.update!(is_current: false)
    assert_difference "AccountRotationEvent.count", -1 do
      secondary.destroy!
    end
  end

  test "destroy nullifies rotation events where account is rotated_from" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    event = AccountRotationEvent.create!(
      rotated_from: primary,
      rotated_to: secondary,
      reason: "quota_exceeded",
      source: "automatic"
    )

    primary.update!(is_current: false)
    primary.destroy!

    event.reload
    assert_nil event.rotated_from_id
    assert_equal secondary.id, event.rotated_to_id
  end

  # permanent_refresh_failure? tests

  test "refresh_token! marks needs_reauth on 400 with standard OAuth error format" do
    account = claude_accounts(:expired_token)

    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)
    assert_not account.refresh_token!

    account.reload
    assert account.needs_reauth?
  end

  test "refresh_token! marks needs_reauth on 400 with Anthropic nested error format" do
    account = claude_accounts(:expired_token)

    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({
      type: "error",
      error: { type: "invalid_request_error", message: "Invalid request format" }
    }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)
    assert_not account.refresh_token!

    account.reload
    assert account.needs_reauth?
  end

  test "refresh_token! does not mark needs_reauth on 503 transient error" do
    account = claude_accounts(:expired_token)

    failed_response = Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable")
    failed_response.stubs(:code).returns("503")
    failed_response.stubs(:body).returns("Service Unavailable")

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)
    assert_not account.refresh_token!

    account.reload
    assert_not account.needs_reauth?
  end

  test "refresh_token! recovery probe logs expected failure at .info, not .error/.warn" do
    account = claude_accounts(:expired_token)
    account.update!(status: :needs_reauth)

    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    # A recovery probe re-fires every cron cycle while a human re-auths; the
    # expected failure must NOT re-trip the ERROR/WARN alert. Allow benign .info
    # (e.g. the filesystem-sync skip message) but require the probe-failure line.
    Rails.logger.stubs(:info)
    Rails.logger.expects(:error).never
    Rails.logger.expects(:warn).never
    Rails.logger.expects(:info).with(regexp_matches(/Recovery probe for .* still failing/)).at_least_once

    assert_not account.refresh_token!(recovery_probe: true)
  end

  test "refresh_token! permanent failure logs at .warn, not .error" do
    account = claude_accounts(:expired_token)

    # 400 invalid_grant is a known-permanent failure: the account is gracefully
    # marked needs_reauth and rotated out, so this must NOT trip the production
    # ERROR alert. It logs a single .warn instead.
    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    Rails.logger.stubs(:info)
    Rails.logger.expects(:error).never
    Rails.logger.expects(:warn).with(regexp_matches(/Refresh token permanently invalid for .* marking needs_reauth/)).at_least_once

    assert_not account.refresh_token!
    assert account.reload.needs_reauth?
  end

  test "refresh_token! unexpected non-2xx response still logs at .error" do
    account = claude_accounts(:expired_token)

    # A 500 is neither a known permanent OAuth error nor a retried transient
    # exception — the refresh path is genuinely broken, so it must still page.
    failed_response = Net::HTTPInternalServerError.new("1.1", "500", "Internal Server Error")
    failed_response.stubs(:code).returns("500")
    failed_response.stubs(:body).returns("upstream is on fire")
    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    Rails.logger.stubs(:warn)
    Rails.logger.stubs(:info)
    Rails.logger.expects(:error).with(regexp_matches(/Token refresh failed for/)).at_least_once

    assert_not account.refresh_token!
    assert_not account.reload.needs_reauth?
  end

  test "refresh_token! transient network error logs at .info, not .error/.warn" do
    account = claude_accounts(:expired_token)

    # A transient open-timeout to the token endpoint: the refresh job retries
    # with backoff, so a single blip must NOT trip the production ERROR alert.
    Net::HTTP.any_instance.stubs(:request).raises(Net::OpenTimeout)

    Rails.logger.stubs(:info)
    Rails.logger.expects(:error).never
    Rails.logger.expects(:warn).never
    Rails.logger.expects(:info).with(regexp_matches(/Token refresh transient error for .*\(will retry\)/)).at_least_once

    assert_not account.refresh_token!
  end

  test "refresh_token! unexpected (non-transient) error still logs at .error" do
    account = claude_accounts(:expired_token)

    # A genuinely unexpected error must remain alertable at .error.
    Net::HTTP.any_instance.stubs(:request).raises(RuntimeError.new("kaboom"))

    Rails.logger.stubs(:warn)
    Rails.logger.stubs(:info)
    Rails.logger.expects(:error).with(regexp_matches(/Token refresh error for .* kaboom/)).at_least_once

    assert_not account.refresh_token!
  end

  # Class-method bootstrap helpers

  test "filesystem_oauth_email returns email from Hash-form oauthAccount" do
    with_claude_account_fs do |fs|
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({
        "oauthAccount" => { "emailAddress" => "hash-form@example.com", "uuid" => "abc-123" }
      }))

      assert_equal "hash-form@example.com", ClaudeAccount.filesystem_oauth_email
    end
  end

  test "filesystem_oauth_email returns email from String-form oauthAccount (legacy)" do
    with_claude_account_fs do |fs|
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({
        "oauthAccount" => "legacy-string@example.com"
      }))

      assert_equal "legacy-string@example.com", ClaudeAccount.filesystem_oauth_email
    end
  end

  test "filesystem_oauth_email returns nil when ~/.claude.json is missing" do
    with_claude_account_fs do |fs|
      # No file written
      assert_nil ClaudeAccount.filesystem_oauth_email
    end
  end

  test "filesystem_oauth_email returns nil for malformed JSON" do
    with_claude_account_fs do |fs|
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, "not json at all {{{")
      assert_nil ClaudeAccount.filesystem_oauth_email
    end
  end

  test "sync_from_filesystem! captures tokens for matching account and marks current when none exist" do
    with_claude_account_fs do |fs|
      # Clear is_current on all accounts to simulate no current state
      ClaudeAccount.update_all(is_current: false)

      # Create a record with empty oauth_config that matches filesystem email
      account = ClaudeAccount.create!(email: "bootstrap@example.com", priority: 10)

      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({
        "oauthAccount" => { "emailAddress" => "bootstrap@example.com" }
      }))
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate({
        "claudeAiOauth" => {
          "accessToken" => "bootstrapped-token",
          "refreshToken" => "bootstrapped-refresh",
          "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
        }
      }))

      result = ClaudeAccount.sync_from_filesystem!

      assert_equal account, result
      account.reload
      assert_equal "bootstrapped-token", account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
      assert account.is_current?, "should mark current when no prior current account existed"
    end
  end

  test "sync_from_filesystem! does not change is_current when another account is already current" do
    with_claude_account_fs do |fs|
      # primary fixture is current
      primary = claude_accounts(:primary)
      assert primary.is_current?

      account = ClaudeAccount.create!(email: "another@example.com", priority: 20)

      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({
        "oauthAccount" => { "emailAddress" => "another@example.com" }
      }))
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate({
        "claudeAiOauth" => {
          "accessToken" => "new-token",
          "refreshToken" => "new-refresh",
          "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
        }
      }))

      result = ClaudeAccount.sync_from_filesystem!

      assert_equal account, result
      assert_not account.reload.is_current?, "should not change current when another is already current"
      assert primary.reload.is_current?
      # Tokens still captured
      assert_equal "new-token", account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    end
  end

  test "sync_from_filesystem! returns nil when no account matches filesystem email" do
    with_claude_account_fs do |fs|
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({
        "oauthAccount" => { "emailAddress" => "nobody@example.com" }
      }))
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate({
        "claudeAiOauth" => { "accessToken" => "x", "refreshToken" => "y", "expiresAt" => 9999999999999 }
      }))

      assert_nil ClaudeAccount.sync_from_filesystem!
    end
  end

  test "sync_from_filesystem! returns nil when filesystem credentials file is missing" do
    with_claude_account_fs do |fs|
      # No files written
      assert_nil ClaudeAccount.sync_from_filesystem!
    end
  end

  test "sync_from_filesystem! resets status to active" do
    with_claude_account_fs do |fs|
      account = ClaudeAccount.create!(email: "revived@example.com", priority: 30, status: :needs_reauth)

      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({
        "oauthAccount" => { "emailAddress" => "revived@example.com" }
      }))
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate({
        "claudeAiOauth" => {
          "accessToken" => "fresh-token",
          "refreshToken" => "fresh-refresh",
          "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
        }
      }))

      ClaudeAccount.sync_from_filesystem!
      assert account.reload.active?, "should reset status to active after successful sync"
    end
  end

  # --- Codex runtime ---

  test "codex? distinguishes runtime" do
    assert claude_accounts(:codex_primary).codex?
    assert_not claude_accounts(:primary).codex?
  end

  test "for_runtime scopes the pool by runtime" do
    codex = ClaudeAccount.for_runtime("codex")
    assert codex.exists?
    assert codex.all?(&:codex?)
    assert_not_includes codex, claude_accounts(:primary)
  end

  test "current_account is scoped per runtime" do
    assert_equal claude_accounts(:primary), ClaudeAccount.current_account("claude_code")
    assert_equal claude_accounts(:codex_primary), ClaudeAccount.current_account("codex")
  end

  test "mark_current! only clears the same runtime's current flag" do
    claude_accounts(:codex_secondary).mark_current!

    assert claude_accounts(:codex_secondary).reload.is_current?
    assert_not claude_accounts(:codex_primary).reload.is_current?
    # The Claude pool's current account is untouched.
    assert claude_accounts(:primary).reload.is_current?
  end

  test "codex token_expires_at is last_refresh + TOKEN_TTL" do
    refreshed_at = Time.utc(2026, 5, 1, 12, 0, 0)
    account = claude_accounts(:codex_primary)
    account.update!(oauth_config: codex_oauth_config(last_refresh: refreshed_at.iso8601))

    assert_in_delta (refreshed_at + CodexAuthProvider::TOKEN_TTL).to_f, account.token_expires_at.to_f, 1
  end

  test "codex token_expires_at is nil for API-key accounts" do
    assert_nil claude_accounts(:codex_api_key).token_expires_at
  end

  test "codex token_expired? is false within the TTL window and true past it" do
    account = claude_accounts(:codex_primary)

    account.update!(oauth_config: codex_oauth_config(last_refresh: 1.hour.ago.utc.iso8601))
    assert_not account.token_expired?

    account.update!(oauth_config: codex_oauth_config(last_refresh: 25.hours.ago.utc.iso8601))
    assert account.token_expired?
  end

  test "codex token_expired? is false for API-key accounts" do
    assert_not claude_accounts(:codex_api_key).token_expired?
  end

  test "codex token_expiring_soon? is true near the end of the TTL window" do
    account = claude_accounts(:codex_primary)
    # Refreshed ~24h ago → expires in ~5 min, inside the 15-min threshold.
    account.update!(oauth_config: codex_oauth_config(last_refresh: (CodexAuthProvider::TOKEN_TTL.ago + 5.minutes).utc.iso8601))

    assert account.token_expiring_soon?(15.minutes)
  end

  test "codex token_expiring_soon? is false for API-key accounts" do
    assert_not claude_accounts(:codex_api_key).token_expiring_soon?
  end

  test "codex can_refresh_token? reflects presence of a refresh token" do
    assert claude_accounts(:codex_primary).can_refresh_token?
    assert_not claude_accounts(:codex_api_key).can_refresh_token?
  end

  test "codex_api_key_account? is true only for API-key accounts" do
    assert claude_accounts(:codex_api_key).codex_api_key_account?
    assert_not claude_accounts(:codex_primary).codex_api_key_account?
  end

  test "codex_api_key and codex_account_id read identity from oauth_config" do
    assert_equal "sk-codex-test-key", claude_accounts(:codex_api_key).codex_api_key
    assert_equal "codex_account_1", claude_accounts(:codex_primary).codex_account_id
    assert_nil claude_accounts(:codex_api_key).codex_account_id
  end

  test "refresh_token! is a no-op success for codex API-key accounts" do
    account = claude_accounts(:codex_api_key)
    Net::HTTP.any_instance.expects(:request).never
    assert account.refresh_token!
  end

  test "codex refresh_token! updates only the fields present in the response and sets last_refresh" do
    with_codex_fs do
      account = claude_accounts(:codex_primary) # is_current: true
      account.update!(oauth_config: codex_oauth_config(last_refresh: 25.hours.ago.utc.iso8601))

      response = Net::HTTPSuccess.new("1.1", "200", "OK")
      response.stubs(:code).returns("200")
      # Response rotates access_token + refresh_token but omits id_token.
      response.stubs(:body).returns({
        access_token: "rotated_access",
        refresh_token: "rotated_refresh"
      }.to_json)
      Net::HTTP.any_instance.stubs(:request).returns(response)

      assert account.refresh_token!
      account.reload

      tokens = account.oauth_config.dig("auth_json", "tokens")
      assert_equal "rotated_access", tokens["access_token"]
      assert_equal "rotated_refresh", tokens["refresh_token"]
      # id_token was absent from the response, so it persists unchanged.
      assert_equal "codex_id_token_1", tokens["id_token"]
      assert_equal "codex_account_1", tokens["account_id"]
      assert_not account.token_expired?, "last_refresh should be bumped to now"

      # Current account: the refreshed envelope is written to ~/.codex/auth.json.
      written = JSON.parse(File.read(CodexAuthProvider::AUTH_JSON_PATH))
      assert_equal "rotated_access", written.dig("tokens", "access_token")
    end
  end

  test "codex refresh_token! marks needs_reauth on HTTP 401" do
    account = claude_accounts(:codex_primary)

    response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    response.stubs(:code).returns("401")
    response.stubs(:body).returns({ error: "unauthorized" }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(response)

    assert_not account.refresh_token!
    assert account.reload.needs_reauth?
  end

  test "codex refresh_token! marks needs_reauth on refresh_token_reused" do
    account = claude_accounts(:codex_primary)

    response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    response.stubs(:code).returns("400")
    response.stubs(:body).returns({ error: { code: "refresh_token_reused" } }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(response)

    assert_not account.refresh_token!
    assert account.reload.needs_reauth?
  end

  test "codex refresh_token! treats a 503 as transient and does not mark needs_reauth" do
    account = claude_accounts(:codex_primary)

    response = Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable")
    response.stubs(:code).returns("503")
    response.stubs(:body).returns("upstream unavailable")
    Net::HTTP.any_instance.stubs(:request).returns(response)

    assert_not account.refresh_token!
    assert_not account.reload.needs_reauth?
  end

  test "codex refresh_token! recovery probe logs expected failure at .info, not .error/.warn" do
    account = claude_accounts(:codex_primary)
    account.update!(status: :needs_reauth)

    response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    response.stubs(:code).returns("401")
    response.stubs(:body).returns({ error: "unauthorized" }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(response)

    # A recovery probe re-fires every cron cycle while a human re-auths; the
    # expected failure must NOT re-trip the ERROR/WARN alert. Allow benign .info
    # (e.g. the filesystem-sync skip message) but require the probe-failure line.
    Rails.logger.stubs(:info)
    Rails.logger.expects(:error).never
    Rails.logger.expects(:warn).never
    Rails.logger.expects(:info).with(regexp_matches(/Codex recovery probe for .* still failing/)).at_least_once

    assert_not account.refresh_token!(recovery_probe: true)
  end

  test "codex refresh_token! permanent failure logs at .warn, not .error" do
    account = claude_accounts(:codex_primary)

    # 401 is a known-permanent Codex failure: the account is gracefully marked
    # needs_reauth and rotated out, so this must NOT trip the production ERROR
    # alert. It logs a single .warn instead.
    response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    response.stubs(:code).returns("401")
    response.stubs(:body).returns({ error: "unauthorized" }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(response)

    Rails.logger.stubs(:info)
    Rails.logger.expects(:error).never
    Rails.logger.expects(:warn).with(regexp_matches(/Codex refresh token permanently invalid for .* marking needs_reauth/)).at_least_once

    assert_not account.refresh_token!
    assert account.reload.needs_reauth?
  end

  test "codex refresh_token! unexpected non-2xx response still logs at .error" do
    account = claude_accounts(:codex_primary)

    # A 500 is neither a known permanent Codex error nor a retried transient
    # exception — the refresh path is genuinely broken, so it must still page.
    response = Net::HTTPInternalServerError.new("1.1", "500", "Internal Server Error")
    response.stubs(:code).returns("500")
    response.stubs(:body).returns("upstream is on fire")
    Net::HTTP.any_instance.stubs(:request).returns(response)

    Rails.logger.stubs(:warn)
    Rails.logger.stubs(:info)
    Rails.logger.expects(:error).with(regexp_matches(/Codex token refresh failed for/)).at_least_once

    assert_not account.refresh_token!
    assert_not account.reload.needs_reauth?
  end

  test "codex refresh_token! transient network error logs at .info, not .error/.warn" do
    account = claude_accounts(:codex_primary)

    # This is the exact failure that tripped the production ERROR alert:
    # Net::OpenTimeout to the OpenAI token endpoint. The refresh job retries it,
    # so it must log at .info and not alert.
    Net::HTTP.any_instance.stubs(:request).raises(Net::OpenTimeout)

    Rails.logger.stubs(:info)
    Rails.logger.expects(:error).never
    Rails.logger.expects(:warn).never
    Rails.logger.expects(:info).with(regexp_matches(/Codex token refresh transient error for .*\(will retry\)/)).at_least_once

    assert_not account.refresh_token!
  end

  test "codex refresh_token! unexpected (non-transient) error still logs at .error" do
    account = claude_accounts(:codex_primary)

    Net::HTTP.any_instance.stubs(:request).raises(RuntimeError.new("kaboom"))

    Rails.logger.stubs(:warn)
    Rails.logger.stubs(:info)
    Rails.logger.expects(:error).with(regexp_matches(/Codex token refresh error for .* kaboom/)).at_least_once

    assert_not account.refresh_token!
  end

  test "sync_codex_tokens_from_filesystem! adopts CLI-rotated tokens when account_id matches" do
    with_codex_fs do
      account = claude_accounts(:codex_primary)

      File.write(CodexAuthProvider::AUTH_JSON_PATH, JSON.generate({
        "OPENAI_API_KEY" => nil,
        "tokens" => {
          "id_token" => "fs_id",
          "access_token" => "fs_access",
          "refresh_token" => "fs_rotated_refresh",
          "account_id" => "codex_account_1"
        },
        "last_refresh" => Time.current.utc.iso8601
      }))

      account.sync_codex_tokens_from_filesystem!
      account.reload

      assert_equal "fs_rotated_refresh", account.oauth_config.dig("auth_json", "tokens", "refresh_token")
    end
  end

  test "sync_codex_tokens_from_filesystem! skips when the filesystem identity does not match" do
    with_codex_fs do
      account = claude_accounts(:codex_primary)
      original_refresh = account.oauth_config.dig("auth_json", "tokens", "refresh_token")

      File.write(CodexAuthProvider::AUTH_JSON_PATH, JSON.generate({
        "tokens" => {
          "access_token" => "other_access",
          "refresh_token" => "other_refresh",
          "account_id" => "some_other_account"
        }
      }))

      account.sync_codex_tokens_from_filesystem!
      account.reload

      assert_equal original_refresh, account.oauth_config.dig("auth_json", "tokens", "refresh_token")
    end
  end

  test "sync_codex_tokens_from_filesystem! skips incomplete filesystem tokens" do
    with_codex_fs do
      account = claude_accounts(:codex_primary)
      original_refresh = account.oauth_config.dig("auth_json", "tokens", "refresh_token")

      # Matching identity but missing refresh_token — must not clobber the DB.
      File.write(CodexAuthProvider::AUTH_JSON_PATH, JSON.generate({
        "tokens" => {
          "access_token" => "fs_access",
          "refresh_token" => "",
          "account_id" => "codex_account_1"
        }
      }))

      account.sync_codex_tokens_from_filesystem!
      account.reload

      assert_equal original_refresh, account.oauth_config.dig("auth_json", "tokens", "refresh_token")
    end
  end

  test "write_codex_auth_to_filesystem! writes the OAuth envelope verbatim" do
    with_codex_fs do
      claude_accounts(:codex_primary).write_codex_auth_to_filesystem!

      written = JSON.parse(File.read(CodexAuthProvider::AUTH_JSON_PATH))
      assert_equal "codex_account_1", written.dig("tokens", "account_id")
      assert_equal "codex_refresh_token_1", written.dig("tokens", "refresh_token")
    end
  end

  test "write_codex_auth_to_filesystem! writes a minimal API-key envelope" do
    with_codex_fs do
      claude_accounts(:codex_api_key).write_codex_auth_to_filesystem!

      written = JSON.parse(File.read(CodexAuthProvider::AUTH_JSON_PATH))
      assert_equal "sk-codex-test-key", written["OPENAI_API_KEY"]
    end
  end

  private

  # Builds a codex oauth_config envelope with a controllable last_refresh so
  # tests can place the account anywhere in its TTL window.
  def codex_oauth_config(last_refresh:, account_id: "codex_account_1",
    id_token: "codex_id_token_1", access_token: "codex_access_token_1",
    refresh_token: "codex_refresh_token_1")
    {
      "auth_json" => {
        "OPENAI_API_KEY" => nil,
        "tokens" => {
          "id_token" => id_token,
          "access_token" => access_token,
          "refresh_token" => refresh_token,
          "account_id" => account_id
        },
        "last_refresh" => last_refresh
      }
    }
  end

  # Redirects ~/.codex/auth.json to a temp dir for the duration of the block so
  # codex filesystem reads/writes never touch the real home directory.
  def with_codex_fs
    tmpdir = Dir.mktmpdir
    original_home = CodexAuthProvider::CODEX_HOME
    original_path = CodexAuthProvider::AUTH_JSON_PATH
    CodexAuthProvider.send(:remove_const, :CODEX_HOME)
    CodexAuthProvider.const_set(:CODEX_HOME, tmpdir)
    CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
    CodexAuthProvider.const_set(:AUTH_JSON_PATH, File.join(tmpdir, "auth.json"))
    yield tmpdir
  ensure
    FileUtils.rm_rf(tmpdir)
    CodexAuthProvider.send(:remove_const, :CODEX_HOME)
    CodexAuthProvider.const_set(:CODEX_HOME, original_home)
    CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
    CodexAuthProvider.const_set(:AUTH_JSON_PATH, original_path)
  end

  # ── completeness invariant + owner marker (cross-container contamination) ──

  test "complete_claude_oauth? requires both accessToken and refreshToken" do
    both = { "claudeAiOauth" => { "accessToken" => "a", "refreshToken" => "r" } }
    no_refresh = { "claudeAiOauth" => { "accessToken" => "a" } }
    no_access = { "claudeAiOauth" => { "refreshToken" => "r" } }
    assert ClaudeAccount.complete_claude_oauth?(both)
    assert_not ClaudeAccount.complete_claude_oauth?(no_refresh)
    assert_not ClaudeAccount.complete_claude_oauth?(no_access)
    assert_not ClaudeAccount.complete_claude_oauth?({})
    assert_not ClaudeAccount.complete_claude_oauth?(nil)
  end

  test "sync_from_filesystem! refuses to bootstrap a refresh-token-less credential set" do
    with_claude_account_fs do
      account = claude_accounts(:primary)
      account.update!(oauth_config: {})
      ClaudeAccount.update_all(is_current: false)

      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({ "oauthAccount" => "tadas@tadasant.com" }))
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate({
        "claudeAiOauth" => { "accessToken" => "orphan-access" } # no refreshToken
      }))

      assert_nil ClaudeAccount.sync_from_filesystem!
      assert_equal({}, account.reload.oauth_config)
    end
  end

  test "write_credentials_to_filesystem! refuses incomplete creds and does not clobber a good disk file" do
    with_claude_account_fs do
      good = { "claudeAiOauth" => { "accessToken" => "good-access", "refreshToken" => "good-refresh" } }
      FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate(good))

      account = claude_accounts(:primary)
      account.update!(oauth_config: { "credentials_json" => { "claudeAiOauth" => { "accessToken" => "only-access" } } })

      account.write_credentials_to_filesystem!

      # The good file on disk is untouched, not overwritten with the incomplete set.
      on_disk = JSON.parse(File.read(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))
      assert_equal "good-access", on_disk.dig("claudeAiOauth", "accessToken")
    end
  end

  test "write_credentials_to_filesystem! stamps the shared owner marker" do
    with_claude_account_fs do
      account = claude_accounts(:primary)
      account.update!(oauth_config: { "credentials_json" => {
        "claudeAiOauth" => { "accessToken" => "a", "refreshToken" => "r" }
      } })

      account.write_credentials_to_filesystem!

      assert_equal account.email, ClaudeAccount.credentials_owner_email
    end
  end

  test "sync_tokens_from_filesystem! refuses cross-account credentials even when ~/.claude.json matches" do
    # The 2026-06-11 contamination regression. The container-local ~/.claude.json
    # claims this account, but the SHARED owner marker says a different account
    # owns the credentials on disk. Trusting ~/.claude.json here is what grafted
    # one account's tokens onto another's row. The marker must win.
    with_claude_account_fs do
      primary = claude_accounts(:primary)   # tadas@tadasant.com
      secondary = claude_accounts(:secondary) # sam@tadasant.com
      before = primary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")

      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({ "oauthAccount" => "tadas@tadasant.com" }))
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate({
        "claudeAiOauth" => { "accessToken" => "someone-elses-token", "refreshToken" => "someone-elses-refresh" }
      }))
      # Marker says SECONDARY owns these credentials, not primary.
      ClaudeAccount.write_credentials_owner_marker!(secondary.email)

      primary.sync_tokens_from_filesystem!

      assert_equal before, primary.reload.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken"),
        "primary must not adopt credentials the marker says belong to secondary"
    end
  end

  test "sync_tokens_from_filesystem! skips when no owner marker exists" do
    with_claude_account_fs do
      primary = claude_accounts(:primary)
      before = primary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")

      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({ "oauthAccount" => "tadas@tadasant.com" }))
      File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate({
        "claudeAiOauth" => { "accessToken" => "new-token", "refreshToken" => "new-refresh" }
      }))
      # No marker written.

      primary.sync_tokens_from_filesystem!

      assert_equal before, primary.reload.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    end
  end

  def with_claude_account_fs
    tmpdir = Dir.mktmpdir
    original_cred_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    original_json_path = ClaudeAuthProvider::CLAUDE_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(tmpdir, ".credentials.json"))
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(tmpdir, "claude.json"))
    FileUtils.mkdir_p(tmpdir)
    yield tmpdir
  ensure
    FileUtils.rm_rf(tmpdir)
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original_cred_path)
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, original_json_path)
  end
end
