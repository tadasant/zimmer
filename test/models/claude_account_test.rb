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

  # effective_status — the status an account PRESENTS, derived from its latest
  # reading rather than from the sticky column.

  test "effective_status reports active for an exceeded account whose windows have cleared" do
    # The production shape: rotation stamped the account on its way past, its
    # windows have since cleared, and QuotaResetCheckerJob has not swept since.
    account = claude_accounts(:exceeded)
    snapshot = quota_snapshot_for(account, utilization_5h: 0.35, reset_5h: 26.minutes.from_now,
      utilization_7d: 0.12, reset_7d: 6.days.from_now)

    assert account.quota_exceeded?, "the column still says exceeded"
    assert_equal "active", account.effective_status(snapshot)
  end

  test "effective_status keeps the label for an account the API is still rejecting" do
    account = claude_accounts(:exceeded)
    snapshot = quota_snapshot_for(account, utilization_5h: 0.0, reset_5h: 2.hours.from_now,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: 3.days.from_now)

    assert_equal "quota_exceeded", account.effective_status(snapshot)
  end

  test "effective_status keeps the label when there is no reading to judge by" do
    account = claude_accounts(:exceeded)

    assert_equal "quota_exceeded", account.effective_status(nil)
  end

  test "effective_status reads the account's own latest snapshot when none is passed" do
    account = claude_accounts(:exceeded)
    quota_snapshot_for(account, utilization_5h: 0.35, reset_5h: 26.minutes.from_now,
      utilization_7d: 0.12, reset_7d: 6.days.from_now)

    assert_equal "active", account.effective_status
  end

  test "effective_status never softens needs_reauth, which only a human clears" do
    account = claude_accounts(:exceeded)
    account.update!(status: :needs_reauth)
    snapshot = quota_snapshot_for(account, utilization_5h: 0.1, reset_5h: 1.hour.from_now,
      utilization_7d: 0.1, reset_7d: 5.days.from_now)

    assert_equal "needs_reauth", account.effective_status(snapshot)
  end

  # .serviceable_for — the one predicate the parking decision and #auth_health
  # both ask, so they cannot answer "does the pool have anything left" differently.

  test "serviceable_for counts an exceeded account whose own reading says the windows are clear" do
    ClaudeAccount.for_runtime("claude_code").update_all(status: ClaudeAccount.statuses[:quota_exceeded])
    account = claude_accounts(:exceeded)
    account.touch
    quota_snapshot_for(account, utilization_5h: 0.35, reset_5h: 26.minutes.from_now,
      utilization_7d: 0.12, reset_7d: 6.days.from_now)

    assert_includes ClaudeAccount.serviceable_for("claude_code"), account
    assert ClaudeAccount.any_serviceable_for?("claude_code"),
      "A pool whose readings say it can serve is not an exhausted pool, whatever its labels say"
  end

  # The reading only outranks the label when it is the newer of the two. A label
  # written AFTER the newest reading was written by something that knew more than
  # the reading does — a runtime-observed quota refusal whose follow-up probe
  # failed — and resurrecting that account would hand back one every spawn path
  # still refuses and the healer's own fresh probe will not restore.
  test "serviceable_for keeps a label written after the reading it would be overruled by" do
    account = claude_accounts(:primary)
    quota_snapshot_for(account, utilization_5h: 0.35, reset_5h: 26.minutes.from_now,
      utilization_7d: 0.12, reset_7d: 6.days.from_now)
    # The label goes on AFTER that reading — a runtime-observed quota refusal
    # whose follow-up probe failed looks exactly like this.
    account.mark_quota_exceeded!
    ClaudeAccount.for_runtime("claude_code").where.not(id: account.id)
      .update_all(status: ClaudeAccount.statuses[:needs_reauth])

    assert_not_includes ClaudeAccount.serviceable_for("claude_code"), account
    assert_not ClaudeAccount.any_serviceable_for?("claude_code"),
      "Where the label is the newer claim, this degrades to `.available` — the safe floor"
  end

  test "serviceable_for keeps an active account without asking for a reading" do
    ClaudeAccountQuotaSnapshot.delete_all

    emails = ClaudeAccount.serviceable_for("claude_code").map(&:email)
    assert_includes emails, claude_accounts(:primary).email
  end

  test "serviceable_for returns accounts in priority order" do
    serviceable = ClaudeAccount.serviceable_for("claude_code")

    assert_equal serviceable.map(&:priority), serviceable.map(&:priority).sort
  end

  # A blank runtime resolves to Claude Code everywhere else in the app; answering
  # "no accounts" for one here would read as an outage.
  test "serviceable_for resolves a blank runtime to the Claude Code pool" do
    assert_equal ClaudeAccount.serviceable_for("claude_code").map(&:id),
      ClaudeAccount.serviceable_for(nil).map(&:id)
    assert ClaudeAccount.any_serviceable_for?("")
  end

  test "serviceable_for drops an account the API is still rejecting" do
    ClaudeAccount.for_runtime("claude_code").update_all(status: ClaudeAccount.statuses[:quota_exceeded])
    ClaudeAccount.for_runtime("claude_code").find_each do |account|
      quota_snapshot_for(account, utilization_5h: 1.0, status_5h: "rejected", reset_5h: 2.hours.from_now,
        utilization_7d: 1.0, status_7d: "rejected", reset_7d: 3.days.from_now)
    end

    assert_empty ClaudeAccount.serviceable_for("claude_code")
    assert_not ClaudeAccount.any_serviceable_for?("claude_code")
  end

  test "serviceable_for takes an unreadable account at its label" do
    ClaudeAccount.for_runtime("claude_code").update_all(status: ClaudeAccount.statuses[:quota_exceeded])
    ClaudeAccountQuotaSnapshot.delete_all

    assert_empty ClaudeAccount.serviceable_for("claude_code"),
      "With no reading there is nothing to overrule the column with"
  end

  test "serviceable_for excludes needs_reauth and credential-less accounts" do
    claude_accounts(:secondary).update!(status: :needs_reauth)

    emails = ClaudeAccount.serviceable_for("claude_code").map(&:email)
    assert_not_includes emails, claude_accounts(:secondary).email
    assert_not_includes emails, claude_accounts(:unconfigured).email, "no credentials, nothing to serve with"
  end

  test "serviceable_for is scoped to one runtime" do
    ClaudeAccount.for_runtime("claude_code").update_all(status: ClaudeAccount.statuses[:needs_reauth])

    assert_empty ClaudeAccount.serviceable_for("claude_code")
    assert ClaudeAccount.any_serviceable_for?("codex"),
      "A drained Claude pool says nothing about the Codex pool"
  end

  test "mark_current! sets is_current and clears others" do
    secondary = claude_accounts(:secondary)
    secondary.mark_current!

    assert secondary.reload.is_current?
    assert_not claude_accounts(:primary).reload.is_current?
    assert_not_nil secondary.last_rotated_to_at
  end

  test "destroying account detaches its snapshots without destroying them" do
    account = claude_accounts(:primary)
    email = account.email
    snapshots = account.quota_snapshots.to_a
    assert snapshots.any?

    assert_no_difference "ClaudeAccountQuotaSnapshot.count" do
      account.destroy
    end

    assert_equal 0, ClaudeAccountQuotaSnapshot.where(claude_account_id: account.id).count
    snapshots.each do |snapshot|
      assert_nil snapshot.reload.claude_account_id
      assert_equal email, snapshot.account_email
    end
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

  test "refresh_token! uses filesystem refresh token when CLI rotated it behind Zimmer" do
    # Simulates the divergence case from issue pulsemcp/pulsemcp#2964: CLI rotated the refresh token
    # on disk (via Anthropic's OAuth rotation during a session) but Zimmer's DB still
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

  test "destroy nullifies rotation events where account is rotated_to" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    event = AccountRotationEvent.create!(
      rotated_from: primary,
      rotated_to: secondary,
      reason: "quota_exceeded",
      source: "automatic"
    )

    secondary.update!(is_current: false)
    assert_no_difference "AccountRotationEvent.count" do
      secondary.destroy!
    end

    event.reload
    assert_nil event.rotated_to_id
    assert_equal secondary.email, event.rotated_to_email
    assert_equal primary.id, event.rotated_from_id
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

  # Refresh-failure classification tests

  test "refresh_token! marks needs_reauth on 400 invalid_grant that says the credential expired" do
    account = claude_accounts(:expired_token)

    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({
      error: "invalid_grant", error_description: "Refresh token expired"
    }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)
    assert_not account.refresh_token!

    account.reload
    assert account.needs_reauth?
  end

  test "refresh_token! marks needs_reauth on 400 invalid_client" do
    account = claude_accounts(:expired_token)

    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({ error: "invalid_client" }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)
    assert_not account.refresh_token!

    account.reload
    assert account.needs_reauth?, "A verdict on the client is not something retrying can change"
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

  # ===========================================================================
  # Single-use refresh token races (#242)
  #
  # Anthropic's refresh tokens are single-use. Two callers presenting the same
  # one means the second is told it is invalid — and reading that as "dead
  # credential" is what drained the pool: 9 permanent-invalid events across four
  # accounts in ten days, with re-authentication not sticking because the next
  # race killed the account again within minutes.
  # ===========================================================================

  # The second caller must not spend a token the first already replaced. It
  # cannot tell by looking at the response — by then the damage is done — so it
  # checks before the request, under the row lock.
  test "refresh_token! skips the request when a concurrent caller already rotated the token" do
    account = claude_accounts(:primary)

    # Model the racer: while this caller waits for the row lock, another one
    # completes a refresh and writes a new pair to the row. Acquiring the lock
    # therefore reveals a token that is no longer the one we set out to spend.
    #
    # This substitutes for the lock rather than exercising it — it is the
    # post-acquire comparison under test here. The lock itself is covered by
    # "performs the whole refresh inside the row lock" below.
    account.define_singleton_method(:with_lock) do |&block|
      rotated = oauth_config.deep_dup
      rotated["credentials_json"]["claudeAiOauth"]["refreshToken"] = "rotated_by_the_other_caller"
      ClaudeAccount.where(id: id).update_all(oauth_config: rotated)
      reload
      block.call
    end

    # Any HTTP call at all is the bug: the token we would present is spent.
    Net::HTTP.any_instance.expects(:request).never

    assert account.refresh_token!,
      "Another caller's completed refresh is this caller's refresh — report success, don't re-spend the token"
  end

  # The other half, driven through the REAL filesystem sync rather than a stub of
  # it. The window this guards is narrow and specific: the CLI rewrites
  # ~/.claude/.credentials.json in the seconds between refresh_token!'s pre-request
  # sync and its post-failure re-sync. Faking the sync would manufacture a
  # divergence the production path cannot produce, and prove nothing.
  test "refresh_token! does not condemn an account that lost the race to a concurrent rotation" do
    tmpdir = Dir.mktmpdir
    original_cred_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    original_json_path = ClaudeAuthProvider::CLAUDE_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(tmpdir, ".credentials.json"))
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(tmpdir, "claude.json"))

    begin
      account = claude_accounts(:primary)
      FileUtils.mkdir_p(tmpdir)
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate(
        "oauthAccount" => { "emailAddress" => account.email }
      ))
      write_credentials = lambda do |refresh_token|
        File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate(
          "claudeAiOauth" => {
            "accessToken" => "access-for-#{refresh_token}",
            "refreshToken" => refresh_token,
            "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
          }
        ))
      end
      write_credentials.call("token-we-will-present")
      ClaudeAccount.write_credentials_owner_marker!(account.email)

      invalid_grant = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
      invalid_grant.stubs(:code).returns("400")
      invalid_grant.stubs(:body).returns({ error: "invalid_grant" }.to_json)

      sent = nil
      Net::HTTP.any_instance.stubs(:request).with do |req|
        sent = URI.decode_www_form(req.body).to_h["refresh_token"]
        # The CLI finishes its own rotation while our request is in flight, so the
        # token we just sent is spent by the time the response comes back.
        write_credentials.call("cli-rotated-while-we-were-in-flight")
        true
      end.returns(invalid_grant)

      assert_not account.refresh_token!, "The refresh itself did fail"
      assert_equal "token-we-will-present", sent

      account.reload
      assert_not account.needs_reauth?,
        "An account whose token was spent by someone else is healthy — condemning it is what drains the pool"
      assert account.active?
      assert_equal "cli-rotated-while-we-were-in-flight", account.claude_refresh_token,
        "The post-failure re-sync should have adopted the CLI's newer token"
    ensure
      FileUtils.rm_rf(tmpdir)
      ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
      ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original_cred_path)
      ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
      ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, original_json_path)
    end
  end

  # The guard must not become a blanket amnesty: a genuinely dead credential is
  # still dead, and the pool still needs it marked so a human is asked to fix it.
  test "refresh_token! still marks needs_reauth when the token did not move and the credential is expired" do
    account = claude_accounts(:primary)

    invalid_grant = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    invalid_grant.stubs(:code).returns("400")
    invalid_grant.stubs(:body).returns({
      error: "invalid_grant", error_description: "Refresh token expired"
    }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(invalid_grant)
    account.stubs(:sync_tokens_from_filesystem!)

    assert_not account.refresh_token!

    assert account.reload.needs_reauth?,
      "No concurrent rotation happened and the credential is aged out, so this is a dead credential"
  end

  # ===========================================================================
  # A stale token value is not a dead credential (#530)
  #
  # lost_refresh_race? can only see a rotation that landed on the shared
  # credentials file, and that file holds one account's tokens at a time. For
  # every account that is NOT the current credentials owner the check therefore
  # has no evidence at all, answers "not a race", and used to hand the caller a
  # licence to condemn. Production bore that out: over eleven days, 14 of the 15
  # accounts marked needs_reauth carried "Refresh token not found or invalid" —
  # a spent value — and exactly one carried "Refresh token expired".
  # ===========================================================================

  test "refresh_token! does not condemn a non-serving account whose token value is merely stale" do
    with_claude_fs do
      # The shared credentials belong to somebody else, which is the normal state
      # for five of the six accounts in the pool. sync_tokens_from_filesystem! is
      # a documented no-op here, so the race check has nothing to compare.
      write_shared_claude_credentials(owner: claude_accounts(:secondary).email, refresh_token: "someone-elses-token")

      account = claude_accounts(:primary)
      presented = account.claude_refresh_token
      Net::HTTP.any_instance.stubs(:request).returns(stale_invalid_grant)

      assert_not account.refresh_token!, "The refresh itself did fail"

      account.reload
      assert_not account.needs_reauth?,
        "Nothing in this response proves the credential is dead, and the race check had no evidence either way"
      assert account.active?
      assert_equal presented, account.claude_refresh_token, "The no-op sync must not have grafted the owner's token on"
      assert_equal 1, account.stale_refresh_failures
    end
  end

  test "refresh_token! condemns a non-serving account once the stale rejections form a pattern" do
    with_claude_fs do
      write_shared_claude_credentials(owner: claude_accounts(:secondary).email, refresh_token: "someone-elses-token")

      account = claude_accounts(:primary)
      Net::HTTP.any_instance.stubs(:request).returns(stale_invalid_grant)

      travel_to Time.current do
        assert_not account.refresh_token!
        assert_not account.reload.needs_reauth?
      end

      travel_to 20.minutes.from_now do
        assert_not account.refresh_token!
        assert_not account.reload.needs_reauth?, "Two rejections are a pattern of two, which is not yet a pattern"
        assert_equal 2, account.stale_refresh_failures
      end

      travel_to 40.minutes.from_now do
        assert_not account.refresh_token!
        assert account.reload.needs_reauth?,
          "A value rejected three times over three quarters of an hour is no longer explained by a live chain"
      end
    end
  end

  test "refresh_token! counts one retry burst as a single stale strike" do
    with_claude_fs do
      write_shared_claude_credentials(owner: claude_accounts(:secondary).email, refresh_token: "someone-elses-token")

      account = claude_accounts(:primary)
      Net::HTTP.any_instance.stubs(:request).returns(stale_invalid_grant)

      # The sweep retries a non-permanent failure three times with backoff. Four
      # attempts at one spent value are one piece of evidence, not four.
      travel_to Time.current do
        4.times { assert_not account.refresh_token! }
      end

      account.reload
      assert_not account.needs_reauth?
      assert_equal 1, account.stale_refresh_failures
    end
  end

  test "refresh_token! forgets stale strikes older than the window" do
    with_claude_fs do
      write_shared_claude_credentials(owner: claude_accounts(:secondary).email, refresh_token: "someone-elses-token")

      account = claude_accounts(:primary)
      account.update_columns(stale_refresh_failures: 2, last_stale_refresh_failure_at: 7.hours.ago)
      Net::HTTP.any_instance.stubs(:request).returns(stale_invalid_grant)

      assert_not account.refresh_token!

      account.reload
      assert_not account.needs_reauth?, "Two strikes from yesterday are two unrelated races, not a failing credential"
      assert_equal 1, account.stale_refresh_failures
    end
  end

  test "refresh_token! condemns a non-serving account immediately when the credential has expired" do
    with_claude_fs do
      write_shared_claude_credentials(owner: claude_accounts(:secondary).email, refresh_token: "someone-elses-token")

      account = claude_accounts(:primary)
      expired = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
      expired.stubs(:code).returns("400")
      expired.stubs(:body).returns({ error: "invalid_grant", error_description: "Refresh token expired" }.to_json)
      Net::HTTP.any_instance.stubs(:request).returns(expired)

      assert_not account.refresh_token!
      assert account.reload.needs_reauth?, "Expiry is the one description that does prove the credential is finished"
    end
  end

  test "a successful refresh clears the stale strikes behind it" do
    account = claude_accounts(:primary)
    account.update_columns(stale_refresh_failures: 2, last_stale_refresh_failure_at: 5.minutes.ago)
    account.stubs(:sync_tokens_from_filesystem!)
    account.stubs(:is_current?).returns(false)

    ok = Net::HTTPOK.new("1.1", "200", "OK")
    ok.stubs(:code).returns("200")
    ok.stubs(:body).returns({ access_token: "fresh", refresh_token: "fresh-refresh", expires_in: 3600 }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(ok)

    assert account.refresh_token!

    account.reload
    assert_equal 0, account.stale_refresh_failures
    assert_nil account.last_stale_refresh_failure_at
  end

  test "adopting a different refresh token clears the stale strikes" do
    account = claude_accounts(:primary)
    account.update_columns(stale_refresh_failures: 2, last_stale_refresh_failure_at: 5.minutes.ago)

    # What a human re-authenticating through /inference does, and what a filesystem
    # sync does. Neither goes through the refresh path, and both start a new chain.
    reauthed = account.oauth_config.deep_dup
    reauthed["credentials_json"]["claudeAiOauth"]["refreshToken"] = "token-from-a-fresh-login"
    account.update!(oauth_config: reauthed)

    assert_equal 0, account.reload.stale_refresh_failures
    assert_nil account.last_stale_refresh_failure_at
  end

  # The other half of the staleness story: a token Zimmer minted but failed to
  # keep. Anthropic spends the presented token the moment it answers, so if the
  # new pair is rolled back the account's whole chain is orphaned — permanently
  # stale, "not found or invalid" forever, and unrecoverable by any probe.
  test "refresh_token! keeps the new token pair even when the filesystem write fails" do
    account = claude_accounts(:primary)
    account.stubs(:sync_tokens_from_filesystem!)
    account.stubs(:is_current?).returns(true)
    account.stubs(:write_credentials_to_filesystem!).raises(Errno::EACCES.new("credentials lock"))

    ok = Net::HTTPOK.new("1.1", "200", "OK")
    ok.stubs(:code).returns("200")
    ok.stubs(:body).returns({ access_token: "fresh", refresh_token: "the-only-live-token", expires_in: 3600 }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(ok)

    assert account.refresh_token!, "The refresh succeeded; a disk problem afterwards does not unsucceed it"
    assert_equal "the-only-live-token", account.reload.claude_refresh_token
  end

  test "refresh_token! treats an invalid_grant with no description at all as a stale value" do
    with_claude_fs do
      write_shared_claude_credentials(owner: claude_accounts(:secondary).email, refresh_token: "someone-elses-token")

      account = claude_accounts(:primary)
      bare = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
      bare.stubs(:code).returns("400")
      bare.stubs(:body).returns({ error: "invalid_grant" }.to_json)
      Net::HTTP.any_instance.stubs(:request).returns(bare)

      assert_not account.refresh_token!
      assert_not account.reload.needs_reauth?,
        "With no description there is nothing to prove the credential is dead, so the safe reading is stale"
      assert_equal 1, account.stale_refresh_failures
      assert_equal :stale, account.last_refresh_failure_reason
    end
  end

  # The debounce must not slide its own anchor forward, or a steady stream of
  # failures inside the window would keep resetting the clock and never strike.
  test "a debounced stale rejection leaves the strike clock where it was" do
    with_claude_fs do
      write_shared_claude_credentials(owner: claude_accounts(:secondary).email, refresh_token: "someone-elses-token")

      account = claude_accounts(:primary)
      Net::HTTP.any_instance.stubs(:request).returns(stale_invalid_grant)

      first_at = nil
      travel_to Time.current do
        assert_not account.refresh_token!
        first_at = account.reload.last_stale_refresh_failure_at
      end

      travel_to 5.minutes.from_now do
        assert_not account.refresh_token!
        assert_equal first_at.to_i, account.reload.last_stale_refresh_failure_at.to_i
        assert_equal 1, account.stale_refresh_failures
      end
    end
  end

  test "condemning an account on strikes clears the strikes behind it" do
    with_claude_fs do
      write_shared_claude_credentials(owner: claude_accounts(:secondary).email, refresh_token: "someone-elses-token")

      account = claude_accounts(:primary)
      account.update_columns(stale_refresh_failures: 2, last_stale_refresh_failure_at: 30.minutes.ago)
      Net::HTTP.any_instance.stubs(:request).returns(stale_invalid_grant)

      assert_not account.refresh_token!

      account.reload
      assert account.needs_reauth?
      assert_equal 0, account.stale_refresh_failures,
        "A re-authed or admin-revived account must start over with a full three chances"
      assert_nil account.last_stale_refresh_failure_at
    end
  end

  test "an oauth_config save that keeps the same refresh token leaves the strikes alone" do
    account = claude_accounts(:primary)
    account.update_columns(stale_refresh_failures: 2, last_stale_refresh_failure_at: 10.minutes.ago)

    # A metadata-only rewrite — the CLI's own state, not a new credential.
    same_token = account.oauth_config.deep_dup
    same_token["claude_json"] = { "oauthAccount" => account.email, "someCliState" => true }
    account.update!(oauth_config: same_token)

    assert_equal 2, account.reload.stale_refresh_failures
  end

  test "a Codex account's strikes reset only when its own refresh token changes" do
    account = claude_accounts(:codex_primary)
    account.update_columns(stale_refresh_failures: 2, last_stale_refresh_failure_at: 10.minutes.ago)

    untouched = account.oauth_config.deep_dup
    untouched["auth_json"]["last_refresh"] = 1.minute.ago.utc.iso8601
    account.update!(oauth_config: untouched)
    assert_equal 2, account.reload.stale_refresh_failures

    rotated = account.oauth_config.deep_dup
    rotated["auth_json"]["tokens"]["refresh_token"] = "a-brand-new-codex-chain"
    account.update!(oauth_config: rotated)
    assert_equal 0, account.reload.stale_refresh_failures
  end

  test "codex refresh_token! condemns once the reuse rejections form a pattern" do
    with_codex_fs do
      account = claude_accounts(:codex_primary)
      response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
      response.stubs(:code).returns("400")
      response.stubs(:body).returns({ error: { code: "refresh_token_reused" } }.to_json)
      Net::HTTP.any_instance.stubs(:request).returns(response)

      travel_to(Time.current) { assert_not account.refresh_token! }
      travel_to(20.minutes.from_now) { assert_not account.refresh_token! }
      assert_not account.reload.needs_reauth?

      travel_to(40.minutes.from_now) { assert_not account.refresh_token! }
      assert account.reload.needs_reauth?
    end
  end

  test "codex refresh_token! keeps the new tokens even when the filesystem write fails" do
    account = claude_accounts(:codex_primary)
    account.stubs(:sync_codex_tokens_from_filesystem!)
    account.stubs(:is_current?).returns(true)
    account.stubs(:write_codex_auth_to_filesystem!).raises(Errno::EACCES.new("auth.json"))

    ok = Net::HTTPOK.new("1.1", "200", "OK")
    ok.stubs(:code).returns("200")
    ok.stubs(:body).returns({ access_token: "fresh", refresh_token: "the-only-live-codex-token" }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(ok)

    assert account.refresh_token!
    assert_equal "the-only-live-codex-token", account.reload.send(:codex_refresh_token)
  end

  # The other half of the "never lose a minted token" story. A rescued filesystem
  # write leaves the pair we just spent sitting on disk under a marker that still
  # vouches for it — so the very next sync would adopt it and overwrite the live
  # token with the dead one. Disowning the marker is what stops that.
  test "a failed filesystem write disowns the credentials marker so the spent pair is never synced back" do
    with_claude_fs do
      account = claude_accounts(:primary)
      write_shared_claude_credentials(owner: account.email, refresh_token: "the-token-we-already-spent")
      account.stubs(:is_current?).returns(true)
      account.stubs(:write_credentials_to_filesystem!).raises(Errno::EACCES.new("credentials lock"))

      ok = Net::HTTPOK.new("1.1", "200", "OK")
      ok.stubs(:code).returns("200")
      ok.stubs(:body).returns({ access_token: "fresh", refresh_token: "the-only-live-token", expires_in: 3600 }.to_json)
      Net::HTTP.any_instance.stubs(:request).returns(ok)

      assert account.refresh_token!
      assert_equal ClaudeAccount::UNOWNED_CREDENTIALS_MARKER, ClaudeAccount.credentials_owner_email

      # The state that used to orphan the chain: a sweep syncing from disk before
      # the next refresh. It must decline, because nobody owns that file now.
      account.send(:sync_tokens_from_filesystem!)
      assert_equal "the-only-live-token", account.reload.claude_refresh_token
    end
  end

  test "sync_tokens_from_filesystem! still adopts a pair the CLI rotated on disk" do
    with_claude_fs do
      account = claude_accounts(:primary)
      write_shared_claude_credentials(owner: account.email, refresh_token: "cli-rotated-this")

      account.send(:sync_tokens_from_filesystem!)

      assert_equal "cli-rotated-this", account.reload.claude_refresh_token
    end
  end

  # The Codex half. auth.json has no owner marker, so the "do not move backwards"
  # rule is answered from last_refresh instead.
  test "sync_codex_tokens_from_filesystem! refuses tokens older than the ones it holds" do
    with_codex_fs do
      account = claude_accounts(:codex_primary)
      fresh = account.oauth_config.deep_dup
      fresh["auth_json"]["tokens"]["refresh_token"] = "the-only-live-codex-token"
      fresh["auth_json"]["last_refresh"] = Time.current.utc.iso8601
      account.update!(oauth_config: fresh)

      File.write(CodexAuthProvider::AUTH_JSON_PATH, JSON.generate(
        "tokens" => {
          "access_token" => "spent-access",
          "refresh_token" => "the-codex-token-we-already-spent",
          "account_id" => account.codex_account_id
        },
        "last_refresh" => 2.hours.ago.utc.iso8601
      ))

      account.send(:sync_codex_tokens_from_filesystem!)

      assert_equal "the-only-live-codex-token", account.reload.send(:codex_refresh_token)
    end
  end

  # Tadas's own hypothesis about why one account flaps: his Codex account carries
  # the same email as his Claude Code one. The shared credentials-owner marker
  # records an email and nothing else, so the tie is real — the runtime check is
  # what breaks it.
  test "a Codex account never owns the shared Claude credentials, even on an email tie" do
    with_claude_fs do
      claude = claude_accounts(:primary)
      codex = ClaudeAccount.create!(email: claude.email, runtime: CodexAuthProvider::RUNTIME,
        oauth_config: codex_oauth_config(last_refresh: 1.hour.ago.utc.iso8601), priority: 9)
      write_shared_claude_credentials(owner: claude.email, refresh_token: "claude-only-token")

      codex.send(:sync_tokens_from_filesystem!)

      assert_nil codex.reload.oauth_config["credentials_json"],
        "Claude's credentials file must not be grafted onto a Codex row that shares its email"
      assert_not codex.send(:filesystem_credentials_owned_by_self?)
      assert claude.send(:filesystem_credentials_owned_by_self?)
    end
  end

  # Mocha replaces with_lock and never yields, so the whole body is dead — which
  # is exactly what makes the second assertion meaningful: if any part of the
  # read-refresh-persist sequence escaped the lock, the request would still fire.
  test "refresh_token! performs the whole refresh inside the row lock" do
    account = claude_accounts(:primary)
    account.expects(:with_lock).once
    Net::HTTP.any_instance.expects(:request).never

    account.refresh_token!
  end

  # The Codex half of the same guard. OpenAI's tokens are single-use too, and
  # lost_refresh_race? routes through a different sync with a different identity
  # gate, so it needs its own coverage.
  test "refresh_token! does not condemn a Codex account that lost the race" do
    account = claude_accounts(:codex_primary)
    presented = account.send(:codex_refresh_token)

    reused = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    reused.stubs(:code).returns("400")
    reused.stubs(:body).returns({ error: "refresh_token_reused" }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(reused)

    # refresh_codex_token! syncs from ~/.codex/auth.json twice: once before the
    # request, and once from lost_refresh_race? after it fails. The CLI's rotation
    # lands between the two, so only the second sync sees the new token — which is
    # precisely the window the guard exists for.
    syncs = 0
    account.define_singleton_method(:sync_codex_tokens_from_filesystem!) do
      syncs += 1
      next if syncs < 2

      rotated = oauth_config.deep_dup
      rotated["auth_json"]["tokens"]["refresh_token"] = "codex-rotated-in-flight"
      update!(oauth_config: rotated)
    end

    assert_not account.refresh_token!
    assert_not account.reload.needs_reauth?,
      "A Codex account whose token was spent by the CLI is healthy, not dead"
    assert_not_equal presented, account.send(:codex_refresh_token)
  end

  # API-key Codex accounts have no token to rotate and so no race to lose; they
  # must not pay for a row lock on every sweep.
  test "refresh_token! skips the lock for an API-key Codex account" do
    account = claude_accounts(:codex_api_key)
    account.expects(:with_lock).never

    assert account.refresh_token!
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

    # An expired refresh token is a known-permanent failure: the account is
    # gracefully marked needs_reauth and rotated out, so this must NOT trip the
    # production ERROR alert. It logs a single .warn instead.
    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({
      error: "invalid_grant", error_description: "Refresh token expired"
    }.to_json)
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

  test "extract_oauth_email handles both CLI oauthAccount shapes" do
    # The one implementation AccountRotationService and ClaudeLoginDriver share.
    assert_equal "hash@example.com",
      ClaudeAccount.extract_oauth_email({ "emailAddress" => "hash@example.com", "uuid" => "abc" })
    assert_equal "legacy@example.com", ClaudeAccount.extract_oauth_email("legacy@example.com")
    assert_nil ClaudeAccount.extract_oauth_email({})
    assert_nil ClaudeAccount.extract_oauth_email("")
    assert_nil ClaudeAccount.extract_oauth_email(nil)
    assert_nil ClaudeAccount.extract_oauth_email({ "uuid" => "no-email-here" })
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

  test "codex refresh_token! marks needs_reauth on refresh_token_expired" do
    account = claude_accounts(:codex_primary)

    response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    response.stubs(:code).returns("400")
    response.stubs(:body).returns({ error: { code: "refresh_token_expired" } }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(response)

    assert_not account.refresh_token!
    assert account.reload.needs_reauth?
  end

  # refresh_token_reused says another holder of the same chain got there first.
  # That is a statement about the value, not about the credential.
  test "codex refresh_token! does not condemn on the first refresh_token_reused" do
    account = claude_accounts(:codex_primary)

    response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    response.stubs(:code).returns("400")
    response.stubs(:body).returns({ error: { code: "refresh_token_reused" } }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(response)

    assert_not account.refresh_token!
    assert_not account.reload.needs_reauth?
    assert_equal 1, account.stale_refresh_failures
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

  # backfill_identity_from_filesystem! — the converge step that lets
  # AccountRotationService#config_file_matches? fail closed (#61).

  test "backfill_identity_from_filesystem! adopts an on-disk identity that names this account" do
    with_claude_account_fs do
      account = claude_accounts(:primary)
      account.update!(oauth_config: account.oauth_config.except("claude_json"))
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({
        "oauthAccount" => { "emailAddress" => account.email }, "numStartups" => 4
      }))

      assert account.backfill_identity_from_filesystem!
      account.reload
      assert_equal account.email, account.oauth_config.dig("claude_json", "oauthAccount", "emailAddress")
      assert_equal 4, account.oauth_config.dig("claude_json", "numStartups")
      assert_equal "test_access_token_1", account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken"),
        "credentials must be left untouched"
    end
  end

  test "backfill_identity_from_filesystem! refuses an identity belonging to another account" do
    with_claude_account_fs do
      account = claude_accounts(:primary)
      account.update!(oauth_config: account.oauth_config.except("claude_json"))
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({
        "oauthAccount" => { "emailAddress" => "someone-else@example.com" }
      }))

      assert_not account.backfill_identity_from_filesystem!
      assert_nil account.reload.oauth_config.dig("claude_json")
    end
  end

  test "backfill_identity_from_filesystem! never overwrites a stored identity" do
    with_claude_account_fs do
      account = claude_accounts(:primary) # already carries claude_json
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate({
        "oauthAccount" => { "emailAddress" => account.email }, "numStartups" => 9
      }))

      assert_not account.backfill_identity_from_filesystem!
      assert_nil account.reload.oauth_config.dig("claude_json", "numStartups")
    end
  end

  test "backfill_identity_from_filesystem! is a no-op with no identity file on disk" do
    with_claude_account_fs do
      account = claude_accounts(:primary)
      account.update!(oauth_config: account.oauth_config.except("claude_json"))

      assert_not account.backfill_identity_from_filesystem!
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

  # A 400 that rejects the VALUE we presented without saying anything about the
  # credential behind it — the response 14 of the 15 production condemnations
  # carried. See https://github.com/tadasant/zimmer/issues/530.
  def stale_invalid_grant
    response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    response.stubs(:code).returns("400")
    response.stubs(:body).returns({
      error: "invalid_grant", error_description: "Refresh token not found or invalid"
    }.to_json)
    response
  end

  # Redirects ~/.claude/.credentials.json (and the owner marker beside it) to a
  # temp dir for the duration of the block, so filesystem reads never touch the
  # real home directory.
  def with_claude_fs
    tmpdir = Dir.mktmpdir
    original_cred_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    original_json_path = ClaudeAuthProvider::CLAUDE_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(tmpdir, ".credentials.json"))
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(tmpdir, "claude.json"))
    yield tmpdir
  ensure
    FileUtils.rm_rf(tmpdir)
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, original_cred_path)
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, original_json_path)
  end

  # Put one account's credentials on the shared filesystem and stamp the marker
  # to match — the state every account in the pool but one is looking at.
  def write_shared_claude_credentials(owner:, refresh_token:)
    File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.generate("oauthAccount" => { "emailAddress" => owner }))
    File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.generate(
      "claudeAiOauth" => {
        "accessToken" => "access-for-#{refresh_token}",
        "refreshToken" => refresh_token,
        "expiresAt" => ((Time.current + 1.hour).to_f * 1000).to_i
      }
    ))
    ClaudeAccount.write_credentials_owner_marker!(owner)
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

  # ── one credential file, two writers (#60) ──

  test "write_credentials_to_filesystem! preserves the mcpOAuth block the MCP writer maintains" do
    # The rotation regression: ClaudeMcpCredentialWriter keeps its mcpOAuth map in
    # the same file this method writes, so a whole-file overwrite silently drops
    # every MCP OAuth credential — which the user meets as "the agent says it needs
    # to authorize this server again".
    with_claude_account_fs do |tmpdir|
      credentials_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH

      with_mcp_writer_credentials_path(credentials_path) do
        writer = ClaudeMcpCredentialWriter.new
        writer.stubs(:macos?).returns(false)
        writer.write!(working_directory: tmpdir, credentials: [ resolved_mcp_credential ])

        account = claude_accounts(:secondary)
        account.update!(oauth_config: { "credentials_json" => {
          "claudeAiOauth" => { "accessToken" => "rotated-access", "refreshToken" => "rotated-refresh" }
        } })

        assert account.write_credentials_to_filesystem!

        on_disk = JSON.parse(File.read(credentials_path))
        assert_equal "rotated-access", on_disk.dig("claudeAiOauth", "accessToken"),
          "the rotated-in account's login tokens must land on disk"
        assert_equal "access-token-xyz", on_disk.dig("mcpOAuth", "notion|abc123", "accessToken"),
          "the other writer's mcpOAuth entry must survive the rotation"
        assert_equal "refresh-token-123", on_disk.dig("mcpOAuth", "notion|abc123", "refreshToken")

        # And the entry is still readable through the writer's own reader, which is
        # what McpOauthRuntimeReconciler uses to capture runtime-refreshed tokens.
        assert_equal "access-token-xyz", writer.read_runtime_credentials["notion|abc123"].access_token
      end
    end
  end

  test "write_credentials_to_filesystem! preserves unknown top-level keys the CLI wrote" do
    with_claude_account_fs do
      credentials_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
      FileUtils.mkdir_p(File.dirname(credentials_path))
      File.write(credentials_path, JSON.generate({
        "claudeAiOauth" => { "accessToken" => "old-access", "refreshToken" => "old-refresh" },
        "someFutureCliBlock" => { "keep" => "me" }
      }))

      account = claude_accounts(:secondary)
      account.update!(oauth_config: { "credentials_json" => {
        "claudeAiOauth" => { "accessToken" => "new-access", "refreshToken" => "new-refresh" }
      } })

      assert account.write_credentials_to_filesystem!

      on_disk = JSON.parse(File.read(credentials_path))
      assert_equal "new-access", on_disk.dig("claudeAiOauth", "accessToken")
      assert_equal({ "keep" => "me" }, on_disk["someFutureCliBlock"])
    end
  end

  test "write_credentials_to_filesystem! does not write back the DB's stale mcpOAuth copy" do
    # sync_tokens_from_filesystem! captures the WHOLE credentials file into
    # oauth_config, so the DB copy carries whatever mcpOAuth map was on disk at the
    # time. Writing that back would resurrect entries McpOauthCredential has since
    # deleted and clobber entries authorized since. On-disk mcpOAuth always wins.
    with_claude_account_fs do
      credentials_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
      FileUtils.mkdir_p(File.dirname(credentials_path))
      File.write(credentials_path, JSON.generate({
        "mcpOAuth" => { "live|key" => { "accessToken" => "live-token" } }
      }))

      account = claude_accounts(:secondary)
      account.update!(oauth_config: { "credentials_json" => {
        "claudeAiOauth" => { "accessToken" => "a", "refreshToken" => "r" },
        "mcpOAuth" => { "revoked|key" => { "accessToken" => "revoked-token" } }
      } })

      assert account.write_credentials_to_filesystem!

      on_disk = JSON.parse(File.read(credentials_path))
      assert_equal [ "live|key" ], on_disk["mcpOAuth"].keys,
        "the stale DB copy of mcpOAuth must not be written back to disk"
    end
  end

  test "write_credentials_to_filesystem! omits mcpOAuth entirely when the file has none" do
    with_claude_account_fs do
      account = claude_accounts(:secondary)
      account.update!(oauth_config: { "credentials_json" => {
        "claudeAiOauth" => { "accessToken" => "a", "refreshToken" => "r" },
        "mcpOAuth" => { "revoked|key" => { "accessToken" => "revoked-token" } }
      } })

      assert account.write_credentials_to_filesystem!

      on_disk = JSON.parse(File.read(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))
      assert_not on_disk.key?("mcpOAuth"),
        "MCP state is the other writer's to install; it is re-injected on every spawn"
    end
  end

  test "the account writer and the MCP credential writer address the same credentials file" do
    # The two writers coordinate through a lock file derived from this path. If the
    # constants ever diverge, the lock stops coordinating anything and #60 returns.
    assert_equal ClaudeAuthProvider::CREDENTIALS_JSON_PATH, ClaudeMcpCredentialWriter::CLAUDE_CREDENTIALS_PATH
  end

  test "write_credentials_to_filesystem! waits for the shared credential-store lock" do
    with_claude_account_fs do
      account = claude_accounts(:secondary)
      account.update!(oauth_config: { "credentials_json" => {
        "claudeAiOauth" => { "accessToken" => "a", "refreshToken" => "r" }
      } })

      holder_ready = Queue.new
      release_holder = Queue.new
      write_finished = Queue.new

      holder = Thread.new do
        ClaudeCredentialStore.with_lock(ClaudeAuthProvider::CREDENTIALS_JSON_PATH) do
          holder_ready << true
          release_holder.pop
        end
      end
      holder_ready.pop

      writer = Thread.new do
        account.write_credentials_to_filesystem!
        write_finished << true
      end

      sleep 0.1
      assert_raises(ThreadError, "the write must block while another writer holds the lock") do
        write_finished.pop(true)
      end
      assert_not File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH)

      release_holder << true
      holder.join(5)
      writer.join(5)

      assert_equal true, write_finished.pop(true)
      assert File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH)
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

  # Points ClaudeMcpCredentialWriter at the same credentials file the account
  # writer is using, so the two writers meet on one file (and one lock) the way
  # they do in production.
  def with_mcp_writer_credentials_path(path)
    klass = ClaudeMcpCredentialWriter
    original = klass::CLAUDE_CREDENTIALS_PATH
    klass.send(:remove_const, :CLAUDE_CREDENTIALS_PATH)
    klass.const_set(:CLAUDE_CREDENTIALS_PATH, path)
    yield
  ensure
    klass.send(:remove_const, :CLAUDE_CREDENTIALS_PATH)
    klass.const_set(:CLAUDE_CREDENTIALS_PATH, original)
  end

  # The account's newest reading, for the effective_status tests. Defaults
  # describe a healthy window so each test only states what it is about.
  def quota_snapshot_for(account, **attributes)
    account.quota_snapshots.create!(
      { trigger: "scheduled", status_5h: "allowed", status_7d: "allowed" }.merge(attributes)
    )
  end

  def resolved_mcp_credential
    ResolvedMcpCredential.new(
      server_name: "notion",
      server_url: "https://mcp.notion.com/v1/mcp",
      client_id: "client-123",
      access_token: "access-token-xyz",
      refresh_token: "refresh-token-123",
      expires_at: 1.hour.from_now,
      scope: nil,
      headers: {},
      credential_key: "notion|abc123"
    )
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
