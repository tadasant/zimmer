# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class RefreshRuntimeAuthTokensJobTest < ActiveJob::TestCase
  setup do
    @tmpdir = Dir.mktmpdir
    @original_claude_json = ClaudeAuthProvider::CLAUDE_JSON_PATH
    @original_credentials_json = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    @original_codex_home = CodexAuthProvider::CODEX_HOME
    @original_codex_auth_json = CodexAuthProvider::AUTH_JSON_PATH

    # Redirect filesystem paths to temp dir to prevent cross-test pollution.
    # Without this, refresh_token! writes to the real ~/.claude/.credentials.json
    # (because primary is is_current: true), and sync_tokens_from_filesystem!
    # reads stale tokens back in subsequent tests.
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(@tmpdir, "claude.json"))
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(@tmpdir, ".credentials.json"))

    # The dispatcher fans out across every registered runtime, so each run also
    # drives the Codex provider. Redirect ~/.codex too so its filesystem
    # reconciliation hooks never touch the runner's real home directory.
    CodexAuthProvider.send(:remove_const, :CODEX_HOME)
    CodexAuthProvider.const_set(:CODEX_HOME, @tmpdir)
    CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
    CodexAuthProvider.const_set(:AUTH_JSON_PATH, File.join(@tmpdir, "auth.json"))

    # Set all accounts to far-future expiry by default so only accounts
    # we explicitly modify will be picked up by the job
    ClaudeAccount.where.not(oauth_config: {}).find_each do |account|
      config = account.oauth_config.deep_dup
      if config.dig("credentials_json", "claudeAiOauth")
        config["credentials_json"]["claudeAiOauth"]["expiresAt"] = ((Time.current + 2.hours).to_f * 1000).to_i
        account.update_columns(oauth_config: config)
      end
    end

    # Prevent filesystem sync from reading real ~/.claude.json and
    # ~/.claude/.credentials.json on the CI runner. Without this stub,
    # sync_current_account_tokens overwrites fixture tokens and expiry
    # with values from the runner's filesystem, causing with_lock reloads
    # to see corrupted state and skip the refresh path entirely.
    # Dedicated sync tests (below) override this stub as needed.
    ClaudeAccount.any_instance.stubs(:sync_tokens_from_filesystem!)
    # Same protection for the Codex sync path (reads ~/.codex/auth.json).
    ClaudeAccount.any_instance.stubs(:sync_codex_tokens_from_filesystem!)
  end

  teardown do
    FileUtils.rm_rf(@tmpdir)
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, @original_claude_json)
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, @original_credentials_json)
    CodexAuthProvider.send(:remove_const, :CODEX_HOME)
    CodexAuthProvider.const_set(:CODEX_HOME, @original_codex_home)
    CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
    CodexAuthProvider.const_set(:AUTH_JSON_PATH, @original_codex_auth_json)
  end

  teardown do
    FileUtils.rm_rf(@tmpdir)
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, @original_claude_json)
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, @original_credentials_json)
    CodexAuthProvider.send(:remove_const, :CODEX_HOME)
    CodexAuthProvider.const_set(:CODEX_HOME, @original_codex_home)
    CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
    CodexAuthProvider.const_set(:AUTH_JSON_PATH, @original_codex_auth_json)
  end

  test "refreshes tokens expiring within 15 minutes" do
    account = claude_accounts(:primary)
    set_expiring_soon!(account, 10.minutes)

    successful_response = stub_successful_response

    Net::HTTP.any_instance.stubs(:request).returns(successful_response)

    RefreshRuntimeAuthTokensJob.perform_now

    account.reload
    assert_equal "new-access-token", account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    assert_equal "new-refresh-token", account.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
  end

  test "does not refresh tokens not expiring soon" do
    account = claude_accounts(:primary)
    original_token = account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")

    Net::HTTP.any_instance.stubs(:request).raises("Should not attempt refresh")

    # Should not raise — the account won't be selected (token expires in 2 hours from setup)
    RefreshRuntimeAuthTokensJob.perform_now

    account.reload
    assert_equal original_token, account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
  end

  test "skips accounts without refresh token" do
    # unconfigured fixture has empty oauth_config, so can_refresh_token? is false
    account = claude_accounts(:unconfigured)
    assert_not account.can_refresh_token?

    Net::HTTP.any_instance.stubs(:request).raises("Should not attempt refresh")

    RefreshRuntimeAuthTokensJob.perform_now
    assert_not account.reload.can_refresh_token?
  end

  test "skips accounts marked needs_reauth" do
    account = claude_accounts(:primary)
    set_expiring_soon!(account, 10.minutes)
    account.update!(status: :needs_reauth)

    Net::HTTP.any_instance.stubs(:request).raises("Should not attempt refresh")

    RefreshRuntimeAuthTokensJob.perform_now
    assert account.reload.needs_reauth?
  end

  test "continues refreshing other accounts when one fails" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)
    set_expiring_soon!(primary, 10.minutes)
    set_expiring_soon!(secondary, 10.minutes)

    # Stub refresh_token! to fail on first, succeed on second
    primary.stubs(:refresh_token!).returns(false)
    secondary.stubs(:refresh_token!).returns(true)

    # Replace accounts_needing_refresh to return our stubbed instances
    RefreshRuntimeAuthTokensJob.any_instance.stubs(:accounts_needing_refresh).returns([ primary, secondary ])

    # One failure shouldn't block the other; transient failure schedules retry
    assert_enqueued_with(job: RefreshRuntimeAuthTokensJob) do
      RefreshRuntimeAuthTokensJob.perform_now
    end
  end

  test "handles exception during refresh and schedules retry" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)
    set_expiring_soon!(primary, 10.minutes)
    set_expiring_soon!(secondary, 10.minutes)

    # Stub refresh_token! to raise on first call, succeed on second
    primary.stubs(:refresh_token!).raises(StandardError, "Network timeout")
    secondary.stubs(:refresh_token!).returns(true)

    # Replace accounts_needing_refresh to return our stubbed instances
    RefreshRuntimeAuthTokensJob.any_instance.stubs(:accounts_needing_refresh).returns([ primary, secondary ])

    # Exception should be caught and the account scheduled for retry
    assert_enqueued_with(job: RefreshRuntimeAuthTokensJob) do
      RefreshRuntimeAuthTokensJob.perform_now
    end
  end

  test "schedules retry for transient failures" do
    account = claude_accounts(:primary)
    set_expiring_soon!(account, 10.minutes)

    failed_response = Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable")
    failed_response.stubs(:code).returns("503")
    failed_response.stubs(:body).returns("Service Unavailable")

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    assert_enqueued_with(job: RefreshRuntimeAuthTokensJob) do
      RefreshRuntimeAuthTokensJob.perform_now
    end
  end

  test "does not schedule retry for permanent failures (needs_reauth)" do
    account = claude_accounts(:primary)
    set_expiring_soon!(account, 10.minutes)

    # 401 triggers permanent failure -> needs_reauth
    failed_response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    failed_response.stubs(:code).returns("401")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    assert_no_enqueued_jobs(only: RefreshRuntimeAuthTokensJob) do
      RefreshRuntimeAuthTokensJob.perform_now
    end

    account.reload
    assert account.needs_reauth?
  end

  test "perform logs needs_reauth permanent failure at .warn, not .error" do
    account = claude_accounts(:primary)
    set_expiring_soon!(account, 10.minutes)

    # 401 triggers a known-permanent failure that gracefully marks needs_reauth.
    failed_response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    failed_response.stubs(:code).returns("401")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    # The gracefully-handled needs_reauth outcome must not page: .warn, never .error.
    # The model's own permanent-failure .warn fires on the same path, so allow any
    # .warn but require the job-level one. .error must never fire on this path.
    Rails.logger.stubs(:info)
    Rails.logger.stubs(:warn)
    Rails.logger.expects(:error).never
    Rails.logger.expects(:warn).with(regexp_matches(/\[RefreshRuntimeAuthTokens\] Permanent failure for .* marked needs_reauth/)).at_least_once

    RefreshRuntimeAuthTokensJob.perform_now

    assert account.reload.needs_reauth?
  end

  test "perform_retry logs needs_reauth permanent failure at .warn, not .error" do
    account = claude_accounts(:expired_token)

    # 401 triggers a known-permanent failure that gracefully marks needs_reauth.
    failed_response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    failed_response.stubs(:code).returns("401")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    # Allow the model's own permanent-failure .warn; require the job-level one.
    Rails.logger.stubs(:info)
    Rails.logger.stubs(:warn)
    Rails.logger.expects(:error).never
    Rails.logger.expects(:warn).with(regexp_matches(/\[RefreshRuntimeAuthTokens\] Permanent failure for .* on retry 1, marked needs_reauth/)).at_least_once

    RefreshRuntimeAuthTokensJob.perform_now(
      retry_account_ids: [ account.id ],
      attempt: 1
    )

    assert account.reload.needs_reauth?
  end

  test "perform_retry logs at .error when retries are exhausted on transient failure" do
    account = claude_accounts(:expired_token)

    # 503 is transient: it never marks needs_reauth, so at the final attempt the
    # retries-exhausted final failure must still page at .error.
    failed_response = Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable")
    failed_response.stubs(:code).returns("503")
    failed_response.stubs(:body).returns("Service Unavailable")

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    # The model logs its own .error for an unexpected non-2xx (503) on each attempt;
    # allow that and require the job-level retries-exhausted .error.
    Rails.logger.stubs(:info)
    Rails.logger.stubs(:warn)
    Rails.logger.stubs(:error)
    Rails.logger.expects(:error).with(regexp_matches(/\[RefreshRuntimeAuthTokens\] Token refresh for .* failed after #{RefreshRuntimeAuthTokensJob::MAX_RETRIES} retries/)).at_least_once

    assert_no_enqueued_jobs(only: RefreshRuntimeAuthTokensJob) do
      RefreshRuntimeAuthTokensJob.perform_now(
        retry_account_ids: [ account.id ],
        attempt: RefreshRuntimeAuthTokensJob::MAX_RETRIES
      )
    end

    assert_not account.reload.needs_reauth?
  end

  test "retry attempt refreshes specified accounts" do
    account = claude_accounts(:expired_token)

    successful_response = stub_successful_response
    Net::HTTP.any_instance.stubs(:request).returns(successful_response)

    RefreshRuntimeAuthTokensJob.perform_now(
      retry_account_ids: [ account.id ],
      attempt: 1
    )

    account.reload
    assert_equal "new-access-token", account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
  end

  test "retry schedules further retry with exponential backoff when still failing" do
    account = claude_accounts(:expired_token)

    failed_response = Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable")
    failed_response.stubs(:code).returns("503")
    failed_response.stubs(:body).returns("Service Unavailable")

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    assert_enqueued_with(job: RefreshRuntimeAuthTokensJob) do
      RefreshRuntimeAuthTokensJob.perform_now(
        retry_account_ids: [ account.id ],
        attempt: 1
      )
    end
  end

  test "retry does not schedule further retry after max retries exhausted" do
    account = claude_accounts(:expired_token)

    failed_response = Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable")
    failed_response.stubs(:code).returns("503")
    failed_response.stubs(:body).returns("Service Unavailable")

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    assert_no_enqueued_jobs(only: RefreshRuntimeAuthTokensJob) do
      RefreshRuntimeAuthTokensJob.perform_now(
        retry_account_ids: [ account.id ],
        attempt: RefreshRuntimeAuthTokensJob::MAX_RETRIES
      )
    end
  end

  test "refreshes multiple accounts with expiring tokens" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)
    tertiary = claude_accounts(:tertiary)
    set_expiring_soon!(primary, 10.minutes)
    set_expiring_soon!(secondary, 5.minutes)
    # tertiary left at 2 hours (not expiring soon)

    successful_response = stub_successful_response
    Net::HTTP.any_instance.stubs(:request).returns(successful_response)

    RefreshRuntimeAuthTokensJob.perform_now

    primary.reload
    secondary.reload
    tertiary.reload

    assert_equal "new-access-token", primary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    assert_equal "new-access-token", secondary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    # tertiary should not have been refreshed
    assert_not_equal "new-access-token", tertiary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
  end

  # Filesystem sync tests (Fix 6)

  test "syncs filesystem tokens for current account before refreshing" do
    primary = claude_accounts(:primary) # is_current: true
    set_expiring_soon!(primary, 10.minutes)

    # Stub sync to verify it's called
    sync_called = false
    ClaudeAccount.any_instance.stubs(:sync_tokens_from_filesystem!).with do
      sync_called = true
      true
    end

    successful_response = stub_successful_response
    Net::HTTP.any_instance.stubs(:request).returns(successful_response)

    RefreshRuntimeAuthTokensJob.perform_now

    assert sync_called, "Job should sync filesystem tokens for current account"
  end

  test "reconciles filesystem identity before syncing tokens" do
    # If a manual `claude /login` switched the filesystem to a different
    # known account, the cron run should adopt it into the DB before
    # syncing — otherwise sync_current_account_tokens targets the wrong
    # account and the operator's switch is lost.
    AccountRotationService.any_instance.expects(:reconcile_with_filesystem!).at_least_once

    successful_response = stub_successful_response
    Net::HTTP.any_instance.stubs(:request).returns(successful_response)

    RefreshRuntimeAuthTokensJob.perform_now
  end

  # Auto-recovery tests (Fix 5)

  test "attempts recovery of needs_reauth accounts with valid refresh token" do
    account = claude_accounts(:primary)
    set_expiring_soon!(account, 10.minutes)
    account.update!(status: :needs_reauth)

    successful_response = stub_successful_response
    Net::HTTP.any_instance.stubs(:request).returns(successful_response)

    RefreshRuntimeAuthTokensJob.perform_now

    account.reload
    assert account.active?, "Account should be recovered to active after successful refresh"
    assert_equal "new-access-token", account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
  end

  test "keeps needs_reauth status when recovery refresh fails" do
    account = claude_accounts(:primary)
    account.update!(status: :needs_reauth)

    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({
      type: "error",
      error: { type: "invalid_request_error", message: "Invalid request format" }
    }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    RefreshRuntimeAuthTokensJob.perform_now

    account.reload
    assert account.needs_reauth?, "Account should remain needs_reauth after failed recovery"
  end

  test "does not attempt recovery for accounts without refresh token" do
    account = claude_accounts(:unconfigured)
    account.update!(status: :needs_reauth)

    Net::HTTP.any_instance.stubs(:request).raises("Should not attempt refresh")

    # Should not raise — unconfigured account skipped
    RefreshRuntimeAuthTokensJob.perform_now

    assert account.reload.needs_reauth?, "Unconfigured account should remain needs_reauth"
  end

  # Anthropic error format test (Fix 3 integration)

  test "does not schedule retry for Anthropic-format permanent failure" do
    account = claude_accounts(:primary)
    set_expiring_soon!(account, 10.minutes)

    # Anthropic's nested error format
    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({
      type: "error",
      error: { type: "invalid_request_error", message: "Invalid request format" }
    }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    assert_no_enqueued_jobs(only: RefreshRuntimeAuthTokensJob) do
      RefreshRuntimeAuthTokensJob.perform_now
    end

    account.reload
    assert account.needs_reauth?, "Anthropic error format should be detected as permanent failure"
  end

  # --- Codex runtime cadence ---

  test "refreshes expiring codex tokens via the OpenAI token endpoint" do
    codex = claude_accounts(:codex_primary) # is_current: true
    set_codex_last_refresh!(codex, 25.hours.ago)

    Net::HTTP.any_instance.stubs(:request).returns(stub_successful_response)

    RefreshRuntimeAuthTokensJob.perform_now

    codex.reload
    assert_equal "new-access-token", codex.oauth_config.dig("auth_json", "tokens", "access_token")
    assert_equal "new-refresh-token", codex.oauth_config.dig("auth_json", "tokens", "refresh_token")
    assert_not codex.token_expired?, "last_refresh should be bumped, clearing expiry"
  end

  test "does not refresh codex tokens that are still fresh (TTL skips most ticks)" do
    # codex_primary's fixture last_refresh is 'now', so it is nowhere near the
    # 24h TTL and must be left untouched on a routine tick.
    codex = claude_accounts(:codex_primary)
    original = codex.oauth_config.dig("auth_json", "tokens", "access_token")

    Net::HTTP.any_instance.stubs(:request).raises("Should not attempt refresh for fresh codex tokens")

    RefreshRuntimeAuthTokensJob.perform_now

    assert_equal original, codex.reload.oauth_config.dig("auth_json", "tokens", "access_token")
  end

  test "never sweeps codex API-key accounts" do
    # API-key accounts have nothing to refresh and never expire.
    api_key = claude_accounts(:codex_api_key)
    original = api_key.oauth_config.deep_dup

    Net::HTTP.any_instance.stubs(:request).raises("Should not attempt refresh for API-key account")

    RefreshRuntimeAuthTokensJob.perform_now

    assert_equal original, api_key.reload.oauth_config
  end

  test "transient codex failure schedules a retry tagged with the codex runtime" do
    codex = claude_accounts(:codex_primary)
    set_codex_last_refresh!(codex, 25.hours.ago)

    failed_response = Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable")
    failed_response.stubs(:code).returns("503")
    failed_response.stubs(:body).returns("Service Unavailable")
    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    assert_enqueued_with(job: RefreshRuntimeAuthTokensJob) do
      RefreshRuntimeAuthTokensJob.perform_now
    end

    retry_job = enqueued_jobs.find { |j| j[:job] == RefreshRuntimeAuthTokensJob }
    assert retry_job[:args].any? { |a| a.is_a?(Hash) && a["runtime"] == "codex" },
      "retry batch should be tagged with the codex runtime"
    assert_not codex.reload.needs_reauth?, "transient failure must not mark needs_reauth"
  end

  test "permanent codex failure (refresh_token_reused) marks needs_reauth without retry" do
    codex = claude_accounts(:codex_primary)
    set_codex_last_refresh!(codex, 25.hours.ago)

    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({ error: { code: "refresh_token_reused" } }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    assert_no_enqueued_jobs(only: RefreshRuntimeAuthTokensJob) do
      RefreshRuntimeAuthTokensJob.perform_now
    end

    assert codex.reload.needs_reauth?
  end

  private

  # Rewrites a codex account's auth.json envelope with the given last_refresh,
  # which drives its TTL-based expiry.
  def set_codex_last_refresh!(account, last_refresh)
    config = account.oauth_config.deep_dup
    config["auth_json"]["last_refresh"] = last_refresh.utc.iso8601
    account.update!(oauth_config: config)
  end

  def set_expiring_soon!(account, time_until_expiry)
    config = account.oauth_config.deep_dup
    config["credentials_json"]["claudeAiOauth"]["expiresAt"] = ((Time.current + time_until_expiry).to_f * 1000).to_i
    account.update!(oauth_config: config)
  end

  def stub_successful_response
    response = Net::HTTPSuccess.new("1.1", "200", "OK")
    response.stubs(:code).returns("200")
    response.stubs(:body).returns({
      access_token: "new-access-token",
      refresh_token: "new-refresh-token",
      expires_in: 3600
    }.to_json)
    response
  end
end
