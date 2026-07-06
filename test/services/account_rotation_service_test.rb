# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class AccountRotationServiceTest < ActiveSupport::TestCase
  setup do
    @service = AccountRotationService.new
    @tmpdir = Dir.mktmpdir
    @original_claude_json = ClaudeAuthProvider::CLAUDE_JSON_PATH
    @original_credentials_json = ClaudeAuthProvider::CREDENTIALS_JSON_PATH

    # Redirect file writes to temp dir. The canonical credential paths live on
    # ClaudeAuthProvider; AccountRotationService and ClaudeAccount both read them
    # at call-time, so a single swap point covers every collaborator.
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(@tmpdir, "claude.json"))
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(@tmpdir, ".credentials.json"))

    # current_account is now DB-authoritative (no filesystem reads)

    # Stub QuotaCheckService.check_with_token to avoid real API calls
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(
        success: true,
        subscription_type: "claude_max",
        rate_limit_tier: "tier_4",
        utilization_5h: 0.5,
        utilization_7d: 0.3,
        status_5h: "allowed",
        status_7d: "allowed",
        reset_5h: 3.hours.from_now,
        reset_7d: 5.days.from_now
      )
    )

    # activate_next_account now always calls refresh_token! to validate tokens
    # against Anthropic's OAuth endpoint. Stub a generic success response so
    # tests that don't explicitly exercise refresh failure get a passing probe.
    successful_refresh = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_refresh.stubs(:code).returns("200")
    successful_refresh.stubs(:body).returns({
      access_token: "stubbed-access-token",
      refresh_token: "stubbed-refresh-token",
      expires_in: 3600
    }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(successful_refresh)
  end

  teardown do
    FileUtils.rm_rf(@tmpdir)
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, @original_claude_json)
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, @original_credentials_json)
  end

  # Simulate a manual `claude /login` on the worker: the CLI writes ~/.claude.json
  # (the new identity) and ~/.claude/.credentials.json (the new tokens) but does
  # NOT touch AO's shared owner marker, which still names the previous owner with
  # an older mtime. This is the only legitimate way to drive reconcile adoption.
  def simulate_manual_cli_login(new_account, previous_owner:)
    ClaudeAccount.write_credentials_owner_marker!(previous_owner.email)
    past = 2.hours.ago.to_time
    File.utime(past, past, ClaudeAuthProvider.credentials_owner_path)

    claude_json = new_account.oauth_config.fetch("claude_json", { "oauthAccount" => new_account.email })
    File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate(claude_json))
    File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH,
      JSON.generate(new_account.oauth_config.fetch("credentials_json", {})))
  end

  test "activate! writes config to filesystem, marks current, and takes a snapshot" do
    secondary = claude_accounts(:secondary)
    initial_snapshot_count = secondary.quota_snapshots.count

    @service.activate!(secondary, snapshot_trigger: "manual_switch")

    secondary.reload
    assert secondary.is_current?
    assert_equal initial_snapshot_count + 1, secondary.quota_snapshots.count

    assert File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH)
    assert File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH)
    claude_json = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    assert_equal secondary.email, claude_json["oauthAccount"]

    # Snapshot trigger is forwarded
    assert_equal "manual_switch", secondary.quota_snapshots.order(created_at: :desc).first.trigger
  end

  test "activate! writes config to filesystem BEFORE marking current" do
    # The atomicity guarantee: callers (including ensure_active_account!'s
    # reconciliation logic) rely on the DB-current account always having
    # its credentials on disk. Inverting this order opens a race where a
    # concurrent current_account read can trigger reconciliation of an
    # account whose credentials haven't been written yet.
    secondary = claude_accounts(:secondary)

    incoming_was_current_at_write_time = nil
    original_write_config = @service.method(:write_config!)
    @service.define_singleton_method(:write_config!) do |account|
      incoming_was_current_at_write_time = ClaudeAccount.find(account.id).is_current? if account.id == secondary.id
      original_write_config.call(account)
    end

    @service.activate!(secondary, snapshot_trigger: "manual_switch")

    assert_not_nil incoming_was_current_at_write_time
    assert_not incoming_was_current_at_write_time,
      "Account must NOT be marked current when write_config! is called"
  end

  test "rotate! marks current account as quota_exceeded and switches to next" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    result = @service.rotate!

    assert result[:success]
    assert_equal secondary, result[:account]
    assert primary.reload.quota_exceeded?
    assert secondary.reload.is_current?
    assert_not primary.reload.is_current?
  end

  test "rotate! creates an AccountRotationEvent" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    assert_difference "AccountRotationEvent.count", 1 do
      @service.rotate!(reason: "quota_exceeded", triggered_by: "session:42")
    end

    event = AccountRotationEvent.last
    assert_equal primary, event.rotated_from
    assert_equal secondary, event.rotated_to
    assert_equal "quota_exceeded", event.reason
    assert_equal "automatic", event.source
    assert_equal "session:42", event.triggered_by
  end

  test "rotate! writes config files for new account" do
    @service.rotate!

    assert File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH)
    assert File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH)

    claude_json = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    assert_equal "sam@tadasant.com", claude_json["oauthAccount"]
  end

  test "rotate! returns failure when no available accounts" do
    # Mark all accounts as quota_exceeded or unconfigured
    ClaudeAccount.active.where.not(oauth_config: {}).each { |a| a.update!(status: :quota_exceeded) }

    result = @service.rotate!

    assert_not result[:success]
    assert_equal "no_available_accounts", result[:reason]
  end

  test "rotate! takes snapshots of both outgoing and incoming accounts" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    initial_primary_count = primary.quota_snapshots.count
    initial_secondary_count = secondary.quota_snapshots.count

    @service.rotate!

    assert_equal initial_primary_count + 1, primary.quota_snapshots.count
    assert_equal initial_secondary_count + 1, secondary.quota_snapshots.count
  end

  test "ensure_active_account! returns current if valid and config matches" do
    primary = claude_accounts(:primary)
    # Write matching config
    @service.write_config!(primary)

    result = @service.ensure_active_account!
    assert_equal primary, result
  end

  test "ensure_active_account! picks first available when no current set" do
    ClaudeAccount.update_all(is_current: false)

    result = @service.ensure_active_account!
    assert_not_nil result
    assert result.is_current?
    assert result.active?
  end

  test "ensure_active_account! writes config when filesystem does not match DB-current account (web UI switch)" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    # Simulate a cross-container switch: worker filesystem has primary's
    # config from an earlier session, then the web UI switches to secondary.
    # The file was written BEFORE the DB switch, so DB wins.
    @service.write_config!(primary) # Worker filesystem has primary's config (older)
    secondary.update!(is_current: true, last_rotated_to_at: 1.hour.from_now)
    ClaudeAccount.where.not(id: secondary.id).update_all(is_current: false)

    # Verify mismatch exists
    claude_json = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    assert_equal "tadas@tadasant.com", claude_json["oauthAccount"]

    result = @service.ensure_active_account!
    assert_equal secondary, result

    # Verify filesystem was updated to match DB
    claude_json = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    assert_equal "sam@tadasant.com", claude_json["oauthAccount"]
  end

  test "ensure_active_account! adopts filesystem account when CLI was manually switched" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    # Simulate: primary was set as current a while ago, then someone SSHed
    # in and ran `claude /login` as secondary (updating the filesystem).
    primary.update!(last_rotated_to_at: 1.hour.ago)

    simulate_manual_cli_login(secondary, previous_owner: primary)

    result = @service.ensure_active_account!

    # Should adopt secondary from filesystem
    assert_equal secondary, result
    assert secondary.reload.is_current?
    assert_not primary.reload.is_current?
  end

  test "ensure_active_account! does not adopt inactive filesystem account" do
    primary = claude_accounts(:primary)
    exceeded = claude_accounts(:exceeded)

    primary.update!(last_rotated_to_at: 1.hour.ago)

    # Write exceeded account's config to filesystem
    @service.write_config!(exceeded)

    result = @service.ensure_active_account!

    # Should NOT adopt exceeded account — write DB-current to disk instead
    assert_equal primary, result
    assert primary.reload.is_current?

    # Verify filesystem was overwritten with primary's config
    claude_json = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    assert_equal "tadas@tadasant.com", claude_json["oauthAccount"]
  end

  # ── reconcile_with_filesystem! ─────────────────────────────────────

  test "reconcile_with_filesystem! adopts filesystem identity when CLI was manually switched" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    # primary is DB-current; CLI was manually switched to secondary on disk.
    primary.update!(last_rotated_to_at: 1.hour.ago)
    simulate_manual_cli_login(secondary, previous_owner: primary)

    result = @service.reconcile_with_filesystem!

    assert_equal secondary, result
    assert secondary.reload.is_current?
    assert_not primary.reload.is_current?
  end

  test "reconcile_with_filesystem! is a no-op when filesystem matches DB" do
    primary = claude_accounts(:primary)
    @service.write_config!(primary)

    result = @service.reconcile_with_filesystem!

    assert_nil result
    assert primary.reload.is_current?
  end

  test "reconcile_with_filesystem! is a no-op when filesystem identity has no DB record" do
    primary = claude_accounts(:primary)
    primary.update!(last_rotated_to_at: 1.hour.ago)

    # Write a filesystem identity that doesn't match any DB account
    File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH,
      JSON.pretty_generate({ "oauthAccount" => "stranger@example.com" }))

    result = @service.reconcile_with_filesystem!

    assert_nil result
    assert primary.reload.is_current?
  end

  test "reconcile_with_filesystem! is a no-op when filesystem identity is inactive" do
    primary = claude_accounts(:primary)
    exceeded = claude_accounts(:exceeded)

    primary.update!(last_rotated_to_at: 1.hour.ago)
    @service.write_config!(exceeded)

    result = @service.reconcile_with_filesystem!

    assert_nil result
    assert primary.reload.is_current?
    assert_not exceeded.reload.is_current?
  end

  test "reconcile_with_filesystem! is a no-op when filesystem identity needs reauth" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    primary.update!(last_rotated_to_at: 1.hour.ago)
    secondary.update!(status: :needs_reauth)
    @service.write_config!(secondary)

    result = @service.reconcile_with_filesystem!

    assert_nil result
    assert primary.reload.is_current?
    assert_not secondary.reload.is_current?
  end

  test "reconcile_with_filesystem! is a no-op when DB switch is newer than filesystem (web UI switch)" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    # Filesystem holds primary's config, but web UI just switched to secondary.
    @service.write_config!(primary)
    secondary.update!(is_current: true, last_rotated_to_at: 1.hour.from_now)
    ClaudeAccount.where.not(id: secondary.id).update_all(is_current: false)

    result = @service.reconcile_with_filesystem!

    # Should NOT adopt primary — DB-current is newer.
    assert_nil result
    assert secondary.reload.is_current?
    assert_not primary.reload.is_current?
  end

  test "reconcile_with_filesystem! is a no-op when no DB-current account is set" do
    ClaudeAccount.update_all(is_current: false)

    # Even if filesystem has a valid identity, with no DB-current we have
    # nothing to reconcile against — bootstrap belongs elsewhere.
    @service.write_config!(claude_accounts(:secondary))

    result = @service.reconcile_with_filesystem!

    assert_nil result
  end

  test "reconcile_with_filesystem! is a no-op when filesystem identity has empty oauth_config" do
    primary = claude_accounts(:primary)
    unconfigured = claude_accounts(:unconfigured)

    primary.update!(last_rotated_to_at: 1.hour.ago)

    # Write filesystem identity matching unconfigured (which has oauth_config: {})
    File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH,
      JSON.pretty_generate({ "oauthAccount" => unconfigured.email }))

    result = @service.reconcile_with_filesystem!

    # Adoption requires has_valid_config?, which unconfigured fails. The
    # explicit "Sync from filesystem" button (sync_from_filesystem!) is the
    # right tool for bootstrapping a config-less account.
    assert_nil result
    assert primary.reload.is_current?
  end

  test "parse_quota_reset_time parses simple time" do
    result = AccountRotationService.parse_quota_reset_time("You've hit your limit · resets 5pm (UTC)")
    assert_not_nil result
    assert_equal 17, result.hour # 5pm = 17:00
  end

  test "parse_quota_reset_time parses time with date" do
    result = AccountRotationService.parse_quota_reset_time("resets Mar 6, 3am (UTC)")
    assert_not_nil result
    assert_equal 3, result.hour
    assert_equal 3, result.month
  end

  test "parse_quota_reset_time returns nil for unparsable string" do
    result = AccountRotationService.parse_quota_reset_time("some random error")
    assert_nil result
  end

  test "parse_quota_reset_time returns nil for blank string" do
    assert_nil AccountRotationService.parse_quota_reset_time(nil)
    assert_nil AccountRotationService.parse_quota_reset_time("")
  end

  test "rotate! syncs filesystem tokens before marking current as exceeded" do
    primary = claude_accounts(:primary)

    # Write updated tokens to filesystem to simulate CLI refresh
    fs_credentials = {
      "claudeAiOauth" => {
        "accessToken" => "cli-refreshed-token",
        "refreshToken" => "cli-refreshed-refresh",
        "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
      }
    }
    credentials_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    FileUtils.mkdir_p(File.dirname(credentials_path))
    File.write(credentials_path, JSON.generate(fs_credentials))

    # Stamp the shared owner marker to primary so sync_tokens_from_filesystem!
    # recognizes primary as the on-disk owner and captures the CLI-rotated tokens.
    File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({ "oauthAccount" => "tadas@tadasant.com" }))
    ClaudeAccount.write_credentials_owner_marker!(primary.email)

    @service.rotate!

    primary.reload
    assert_equal "cli-refreshed-token", primary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    assert primary.quota_exceeded?
  end

  test "rotate! refreshes expired tokens for incoming account" do
    # Make secondary have expired tokens
    secondary = claude_accounts(:secondary)
    config = secondary.oauth_config.deep_dup
    config["credentials_json"]["claudeAiOauth"]["expiresAt"] = 1000000000000
    secondary.update!(oauth_config: config)

    successful_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_response.stubs(:code).returns("200")
    successful_response.stubs(:body).returns({
      access_token: "refreshed-secondary-token",
      refresh_token: "refreshed-secondary-refresh",
      expires_in: 3600
    }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(successful_response)

    result = @service.rotate!
    assert result[:success]
    assert_equal secondary, result[:account]

    secondary.reload
    assert_equal "refreshed-secondary-token", secondary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    assert secondary.is_current?
  end

  test "rotate! skips account with failed refresh and tries next without bricking it" do
    secondary = claude_accounts(:secondary)
    tertiary = claude_accounts(:tertiary)

    # 503 -> permanent_refresh_failure? returns false, so refresh_token! does
    # NOT mark needs_reauth — this tests the rotation service's behavior.
    failed_response = Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable")
    failed_response.stubs(:code).returns("503")
    failed_response.stubs(:body).returns("Service Unavailable")

    successful_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_response.stubs(:code).returns("200")
    successful_response.stubs(:body).returns({
      access_token: "tertiary-token",
      refresh_token: "tertiary-refresh",
      expires_in: 3600
    }.to_json)

    # Secondary refresh fails (503), then tertiary refresh succeeds
    Net::HTTP.any_instance.stubs(:request).returns(failed_response, successful_response)

    result = @service.rotate!
    assert result[:success]
    assert_equal tertiary, result[:account]

    # Secondary should NOT be marked needs_reauth by the rotation service.
    # The rotation service skips accounts with failed refresh but does not brick them.
    secondary.reload
    assert_not secondary.needs_reauth?, "Rotation should not mark accounts as needs_reauth on transient failure"
    assert secondary.active?, "Account should remain active after transient refresh failure during rotation"
    assert tertiary.reload.is_current?
  end

  test "rotate! allows refresh_token! to mark needs_reauth for permanent failures" do
    secondary = claude_accounts(:secondary)
    tertiary = claude_accounts(:tertiary)

    # 401 triggers permanent_refresh_failure? -> refresh_token! marks needs_reauth
    failed_response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    failed_response.stubs(:code).returns("401")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    successful_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_response.stubs(:code).returns("200")
    successful_response.stubs(:body).returns({
      access_token: "tertiary-token",
      refresh_token: "tertiary-refresh",
      expires_in: 3600
    }.to_json)

    # Secondary refresh fails (401, permanent), then tertiary refresh succeeds
    Net::HTTP.any_instance.stubs(:request).returns(failed_response, successful_response)

    result = @service.rotate!
    assert result[:success]
    assert_equal tertiary, result[:account]

    # needs_reauth was set by refresh_token! (permanent failure), not by the rotation service
    secondary.reload
    assert secondary.needs_reauth?
    assert tertiary.reload.is_current?
  end

  test "rotate! validates tokens via OAuth probe even when expiresAt looks fresh by date" do
    # Production bug repro: an account whose tokens look fresh by date
    # (expiresAt = 9999999999999, the fixture sentinel) but whose refresh
    # token is rejected by Anthropic. Before the fix, the date-only check
    # let these tokens through, write_config! wrote bogus credentials to
    # ~/.claude/.credentials.json, and every subsequent session 401'd.
    # Expected behavior: the probe fails, rotation skips this account, and
    # the bogus credentials are NOT written to the filesystem.
    secondary = claude_accounts(:secondary) # expiresAt: 9999999999999, fake refresh token
    tertiary = claude_accounts(:tertiary)

    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    successful_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_response.stubs(:code).returns("200")
    successful_response.stubs(:body).returns({
      access_token: "tertiary-fresh-token",
      refresh_token: "tertiary-fresh-refresh",
      expires_in: 3600
    }.to_json)

    # First refresh call (secondary, bogus tokens) → 400 invalid_grant
    # Second refresh call (tertiary, real tokens) → 200 success
    Net::HTTP.any_instance.stubs(:request).returns(failed_response, successful_response)

    result = @service.rotate!

    assert result[:success]
    assert_equal tertiary, result[:account]
    assert_not secondary.reload.is_current?, "Secondary must not become current — its probe failed"
    assert tertiary.reload.is_current?

    # The critical assertion: secondary's bogus credentials must NOT have been
    # written to the filesystem. The file should hold tertiary's identity.
    assert File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH)
    claude_json = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    assert_equal "peter@tadasant.com", claude_json["oauthAccount"],
      "Secondary's bogus config must not be written to filesystem when its OAuth probe fails"
  end

  test "rotate! returns no_available_accounts when every candidate fails token validation" do
    # All non-current accounts have unverifiable tokens. The rotation should
    # exhaust the pool and return failure rather than write bogus config.
    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    primary = claude_accounts(:primary)
    pre_existing_fs = File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH)

    result = @service.rotate!

    assert_not result[:success]
    assert_equal "no_available_accounts", result[:reason]
    assert_not pre_existing_fs, "No filesystem write should occur when every candidate fails validation"
  end

  test "rotate! writes config before marking current to prevent reconciliation race" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    # Verify that when write_config! is called for the incoming account,
    # that account is NOT yet marked as current in the DB
    incoming_was_current_at_write_time = nil
    original_write_config = @service.method(:write_config!)
    @service.define_singleton_method(:write_config!) do |account|
      # Check if this is the incoming account (not the outgoing one being written during rotation)
      if account.id == secondary.id
        incoming_was_current_at_write_time = ClaudeAccount.find(account.id).is_current?
      end
      original_write_config.call(account)
    end

    @service.rotate!

    assert_not_nil incoming_was_current_at_write_time,
      "write_config! should have been called for the incoming account"
    assert_not incoming_was_current_at_write_time,
      "Account should NOT be marked current when write_config! is called — write must happen before mark_current!"
  end

  # Bootstrap-from-filesystem tests

  test "ensure_active_account! bootstraps from filesystem when no DB account is current or available" do
    # Simulate the broken-prod state: accounts exist in DB with empty oauth_config
    # (user ran `claude_accounts:add` but skipped `capture_tokens`), and no account
    # is marked current. Filesystem has valid tokens from a recent CLI login.
    ClaudeAccount.destroy_all
    account = ClaudeAccount.create!(email: "bootstrap@example.com", priority: 0)

    File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({
      "oauthAccount" => { "emailAddress" => "bootstrap@example.com" }
    }))
    File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate({
      "claudeAiOauth" => {
        "accessToken" => "bootstrap-token",
        "refreshToken" => "bootstrap-refresh",
        "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
      }
    }))

    result = @service.ensure_active_account!

    assert_equal account, result
    account.reload
    assert account.is_current?
    assert account.has_valid_config?
    assert_equal "bootstrap-token", account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
  end

  test "ensure_active_account! returns nil when no accounts match filesystem email" do
    # No DB account matches the filesystem identity, and no account has valid config
    ClaudeAccount.destroy_all
    ClaudeAccount.create!(email: "not-matching@example.com", priority: 0)

    File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({
      "oauthAccount" => { "emailAddress" => "filesystem-only@example.com" }
    }))
    File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate({
      "claudeAiOauth" => { "accessToken" => "x", "refreshToken" => "y", "expiresAt" => 9999999999999 }
    }))

    result = @service.ensure_active_account!
    assert_nil result
  end

  test "ensure_active_account! returns nil when no filesystem tokens exist and no DB config" do
    ClaudeAccount.destroy_all
    ClaudeAccount.create!(email: "empty-db@example.com", priority: 0)

    # No filesystem files written (setup makes tmpdir but no contents)
    result = @service.ensure_active_account!
    assert_nil result
  end

  test "activate! captures outgoing's CLI-rotated filesystem tokens before overwriting" do
    # The bricked-rotation scenario: while account A is current, the Claude CLI
    # refreshes its tokens, rotating refresh_token. AO's DB copy stays stale.
    # User then switches to account B via the web UI. Without this hardening,
    # write_config!(B) overwrites the credentials file with B's tokens — A's
    # CLI-rotated refresh_token is lost forever, and the next attempt to
    # switch to (or auto-rotate to) A fails with invalid_grant.
    primary = claude_accounts(:primary)   # outgoing, is_current: true
    secondary = claude_accounts(:secondary) # incoming

    # Filesystem reflects primary's identity + CLI-rotated tokens
    cli_rotated = {
      "claudeAiOauth" => {
        "accessToken" => "cli-rotated-access",
        "refreshToken" => "cli-rotated-refresh",
        "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
      }
    }
    FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))
    File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate(cli_rotated))
    File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({ "oauthAccount" => primary.email }))
    # The shared owner marker names primary as the on-disk owner (AO wrote primary's
    # config last; the CLI then rotated the tokens in place without changing identity).
    ClaudeAccount.write_credentials_owner_marker!(primary.email)

    # Confirm DB has stale (pre-rotation) tokens
    pre_db = primary.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
    assert_not_equal "cli-rotated-refresh", pre_db

    @service.activate!(secondary, snapshot_trigger: "manual_switch")

    # Outgoing's CLI-rotated tokens must have been captured to its DB row
    primary.reload
    assert_equal "cli-rotated-access", primary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    assert_equal "cli-rotated-refresh", primary.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")

    # And incoming is now current with its own credentials on disk
    assert secondary.reload.is_current?
    claude_json = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    assert_equal secondary.email, claude_json["oauthAccount"]
  end

  test "activate! does not blow up when no filesystem identity exists" do
    # First-time bootstrap path: nothing on disk, nobody to capture from.
    secondary = claude_accounts(:secondary)
    # No filesystem files written

    assert_nothing_raised do
      @service.activate!(secondary, snapshot_trigger: "manual_switch")
    end

    assert secondary.reload.is_current?
  end

  test "activate! skips outgoing capture when filesystem identity matches incoming" do
    # If the filesystem already holds the incoming account's identity (e.g.,
    # auto-rotation that already wrote config in #activate_next_account, or
    # a re-activation of the current account), there is no outgoing to capture.
    secondary = claude_accounts(:secondary)
    @service.write_config!(secondary)

    # capture_outgoing_filesystem_tokens should be a no-op here (fs_account == incoming).
    # We assert by asserting that activate! completes and incoming is current.
    assert_nothing_raised do
      @service.activate!(secondary, snapshot_trigger: "manual_switch")
    end
    assert secondary.reload.is_current?
  end

  test "ensure_active_account! DB-wins branch captures fs_account's CLI-rotated tokens before overwriting" do
    # The cross-container/web-UI-switch reconciliation path: web container
    # switched DB to secondary, but the worker's filesystem still has primary's
    # config (with CLI-rotated tokens) from before the switch. The DB-wins
    # branch overwrites the filesystem with secondary's config — without this
    # hardening, primary's CLI-rotated refresh_token is lost.
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    # DB switch is more recent than filesystem mtime → DB wins
    @service.write_config!(primary) # filesystem holds primary's identity
    secondary.update!(is_current: true, last_rotated_to_at: 1.hour.from_now)
    ClaudeAccount.where.not(id: secondary.id).update_all(is_current: false)

    # Overwrite filesystem credentials with CLI-rotated tokens for primary
    cli_rotated = {
      "claudeAiOauth" => {
        "accessToken" => "primary-cli-rotated",
        "refreshToken" => "primary-cli-rotated-refresh",
        "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
      }
    }
    File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate(cli_rotated))

    pre_db_refresh = primary.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
    assert_not_equal "primary-cli-rotated-refresh", pre_db_refresh

    result = @service.ensure_active_account!
    assert_equal secondary, result

    # Filesystem now holds secondary's identity (DB won)
    claude_json = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    assert_equal secondary.email, claude_json["oauthAccount"]

    # And primary's CLI-rotated tokens were captured before the overwrite
    primary.reload
    assert_equal "primary-cli-rotated", primary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    assert_equal "primary-cli-rotated-refresh", primary.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
  end

  # ── owner marker (cross-container safety) ──────────────────────────

  test "ensure_active_account! bootstraps the owner marker when missing" do
    primary = claude_accounts(:primary) # is_current: true, identity tadas@tadasant.com
    # Filesystem matches DB identity but there is no marker yet (post-deploy).
    @service.write_config!(primary)
    File.delete(ClaudeAuthProvider.credentials_owner_path) if File.exist?(ClaudeAuthProvider.credentials_owner_path)
    assert_nil ClaudeAccount.credentials_owner_email

    @service.ensure_active_account!

    assert_equal primary.email, ClaudeAccount.credentials_owner_email
  end

  test "capture_outgoing identifies the owner by marker, ignoring a stale ~/.claude.json" do
    # The web-container contamination scenario: the container-local ~/.claude.json
    # names secondary, but the shared marker (and the actual on-disk credentials)
    # belong to primary. Activating a third identity must capture primary's
    # CLI-rotated tokens — driven by the marker — and must NOT touch secondary.
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)
    incoming = claude_accounts(:exceeded)
    incoming.update!(status: :active)

    cli_rotated = { "claudeAiOauth" => {
      "accessToken" => "primary-rotated", "refreshToken" => "primary-rotated-refresh",
      "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
    } }
    FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))
    File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate(cli_rotated))
    # Stale local identity says secondary; marker (shared truth) says primary.
    File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({ "oauthAccount" => secondary.email }))
    ClaudeAccount.write_credentials_owner_marker!(primary.email)

    secondary_before = secondary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")

    @service.activate!(incoming, snapshot_trigger: "rotation")

    # primary (the true owner per the marker) captured its CLI-rotated tokens...
    assert_equal "primary-rotated", primary.reload.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    # ...and secondary (named only by the stale ~/.claude.json) was left alone.
    assert_equal secondary_before, secondary.reload.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
  end
end
