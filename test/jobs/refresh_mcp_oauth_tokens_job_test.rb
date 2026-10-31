# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class RefreshMcpOauthTokensJobTest < ActiveJob::TestCase
  # The ambiguous-failure streak lives in Rails.cache, which is a null_store in
  # test; a real store per test keeps one test's streak out of the next.
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "refreshes tokens expiring within 1 hour" do
    credential = mcp_oauth_credentials(:expiring_soon)
    original_token = credential.access_token

    successful_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_response.stubs(:code).returns("200")
    successful_response.stubs(:body).returns({
      access_token: "freshly-refreshed-token",
      refresh_token: "new-refresh-token",
      expires_in: 3600
    }.to_json)

    stub_token_post(successful_response) do
      RefreshMcpOauthTokensJob.perform_now
    end

    credential.reload
    assert_equal "freshly-refreshed-token", credential.access_token
    assert_equal "new-refresh-token", credential.refresh_token
    assert credential.active?, "Token should be active after refresh"
  end

  test "does not refresh tokens not expiring soon" do
    credential = mcp_oauth_credentials(:notion)
    # Ensure it expires well beyond the 1-hour window
    credential.update!(expires_at: 3.hours.from_now)

    stub_token_post(->(*) { raise "Should not attempt refresh" }) do
      RefreshMcpOauthTokensJob.perform_now
    end

    # Token should remain unchanged
    credential.reload
    assert_equal "test-access-token-12345", credential.access_token
  end

  test "throttles proactive refresh for a credential rotated within the interval" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)
    # Simulate a recent rotation 1h ago — inside the 4h PROACTIVE_REFRESH_MIN_INTERVAL
    # window, so credentials_needing_refresh must filter this credential out.
    credential.update_column(:updated_at, 1.hour.ago)

    # Assert on the network boundary, not on resulting state: throttling means the
    # token endpoint is never contacted at all. (A state-only assertion would also
    # pass if refresh were attempted and merely failed, so it wouldn't prove the
    # throttle.)
    McpOauthService.any_instance.expects(:post_form).never

    RefreshMcpOauthTokensJob.perform_now

    # Token left untouched — proactive rotation was skipped
    credential.reload
    assert_equal "soon-expiring-access-token", credential.access_token
    assert credential.can_refresh?
  end

  test "skips credentials without refresh_token" do
    credential = mcp_oauth_credentials(:expired)
    # expired fixture has no refresh_token

    stub_token_post(->(*) { raise "Should not attempt refresh" }) do
      RefreshMcpOauthTokensJob.perform_now
    end
  end

  test "permanent refresh failure drops the refresh token, preserves a still-valid access token, and is skipped on later runs" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)
    original_token = credential.access_token

    failed_response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    failed_response.stubs(:code).returns("401")
    failed_response.stubs(:body).returns({
      error: "invalid_grant",
      error_description: "Grant not found"
    }.to_json)

    McpOauthService.any_instance.expects(:post_form).once.returns(failed_response)

    log_output = capture_rails_logs do
      # Should not raise
      RefreshMcpOauthTokensJob.perform_now
    end

    credential.reload
    # Access token (still valid) is preserved — the live session is not stranded
    assert_equal original_token, credential.access_token
    assert credential.active?, "still-valid access token should be preserved"
    # Dead refresh token is dropped so it can never be re-sent
    assert_nil credential.refresh_token
    assert_not credential.can_refresh?
    # Re-auth is not forced while the access token remains valid
    assert_not credential.requires_reauth?
    assert_includes log_output, "WARN"
    assert_includes log_output, "Token refresh permanently invalid"
    assert_not_includes log_output, "ERROR"

    # No refresh_token left → filtered out of later scheduled runs
    McpOauthService.any_instance.expects(:post_form).never
    RefreshMcpOauthTokensJob.perform_now
  end

  # zimmer#1427: a one-off 503 from Granola's token endpoint paged #alerts because
  # an HTTP 5xx answer skipped the retry ladder and logged at .error on attempt one.
  test "transient 503 response logs at info and schedules a retry, keeping the credential refreshable" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)
    original_token = credential.access_token
    original_refresh_token = credential.refresh_token

    log_output = capture_rails_logs do
      assert_enqueued_with(job: RefreshMcpOauthTokensJob, args: [ { retry_credential_ids: [ credential.id ], attempt: 1 } ]) do
        stub_token_post(token_endpoint_response(503, { message: "Service Unavailable", code: "503" }.to_json)) do
          RefreshMcpOauthTokensJob.perform_now
        end
      end
    end

    assert_includes log_output, "Transient token endpoint response refreshing"
    assert_includes log_output, "(will retry)"
    assert_includes log_output, "scheduling retry 1/#{RefreshMcpOauthTokensJob::MAX_RETRIES}"
    assert_not_includes log_output, "ERROR"

    credential.reload
    assert_equal original_token, credential.access_token
    assert_equal original_refresh_token, credential.refresh_token
    assert credential.can_refresh?
  end

  test "429 response on an intermediate retry schedules the next retry at info" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)

    log_output = capture_rails_logs do
      assert_enqueued_with(job: RefreshMcpOauthTokensJob, args: [ { retry_credential_ids: [ credential.id ], attempt: 2 } ]) do
        stub_token_post(token_endpoint_response(429, "Too Many Requests")) do
          RefreshMcpOauthTokensJob.perform_now(retry_credential_ids: [ credential.id ], attempt: 1)
        end
      end
    end

    assert_includes log_output, "scheduling retry 2/#{RefreshMcpOauthTokensJob::MAX_RETRIES}"
    assert_not_includes log_output, "ERROR"
  end

  test "503 response persisting past MAX_RETRIES escalates to error and stops retrying" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)

    log_output = capture_rails_logs do
      assert_no_enqueued_jobs(only: RefreshMcpOauthTokensJob) do
        stub_token_post(token_endpoint_response(503, "Service Unavailable")) do
          RefreshMcpOauthTokensJob.perform_now(
            retry_credential_ids: [ credential.id ],
            attempt: RefreshMcpOauthTokensJob::MAX_RETRIES
          )
        end
      end
    end

    assert_includes log_output, "ERROR"
    assert_includes log_output, "failed after #{RefreshMcpOauthTokensJob::MAX_RETRIES} retries"
    assert_includes log_output, "503 - Service Unavailable"
    assert credential.reload.can_refresh?
  end

  test "ambiguous 5xx response with a still-valid access token is not re-sent in-band and stays at info" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)
    original_refresh_token = credential.refresh_token
    assert credential.active?

    [ 500, 502, 504 ].each do |status|
      Rails.cache.clear
      log_output = capture_rails_logs do
        assert_no_enqueued_jobs(only: RefreshMcpOauthTokensJob) do
          stub_token_post(token_endpoint_response(status, "upstream broke")) do
            RefreshMcpOauthTokensJob.perform_now
          end
        end
      end

      assert_includes log_output, "Ambiguous token endpoint response refreshing"
      assert_includes log_output, "will re-attempt on the next scheduled run"
      assert_not_includes log_output, "ERROR", "a #{status} with a live access token should not page"
    end

    credential.reload
    assert_equal original_refresh_token, credential.refresh_token
    assert credential.can_refresh?
  end

  # The cron selects a credential about 3h after a ~1h access token lapsed (the 4h
  # PROACTIVE_REFRESH_MIN_INTERVAL throttle), so escalation keys on consecutive
  # failed runs, not on whether the access token is still valid.
  test "ambiguous 5xx response failing on consecutive scheduled runs logs at error from the second run on" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)
    credential.update_columns(expires_at: 3.hours.ago, updated_at: 5.hours.ago)

    logs = 3.times.map do
      capture_rails_logs do
        assert_no_enqueued_jobs(only: RefreshMcpOauthTokensJob) do
          stub_token_post(token_endpoint_response(502, "Bad Gateway")) do
            RefreshMcpOauthTokensJob.perform_now
          end
        end
      end
    end

    assert_not_includes logs[0], "ERROR", "a first 502 is a blip, even with a lapsed access token"
    assert_includes logs[0], "Ambiguous token endpoint response refreshing"
    logs[1..].each do |log_output|
      assert_includes log_output, "ERROR"
      assert_includes log_output, "still failing (ambiguous token endpoint response"
      assert_includes log_output, "502 - Bad Gateway"
    end
    assert credential.reload.can_refresh?, "the next run must still be able to try"
  end

  test "ambiguous network error failing on consecutive scheduled runs logs at error on the second run" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)

    logs = 2.times.map do
      capture_rails_logs do
        stub_token_post(->(*) { raise Net::ReadTimeout, "Connection timed out" }) do
          RefreshMcpOauthTokensJob.perform_now
        end
      end
    end

    assert_not_includes logs[0], "ERROR"
    assert_includes logs[1], "ERROR"
    assert_includes logs[1], "still failing (ambiguous network failure"
  end

  test "a successful refresh resets the ambiguous-failure streak" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)

    stub_token_post(token_endpoint_response(502, "Bad Gateway")) { RefreshMcpOauthTokensJob.perform_now }
    stub_token_post(token_endpoint_response(200, { access_token: "fresh", expires_in: 1 }.to_json)) do
      RefreshMcpOauthTokensJob.perform_now
    end
    assert_nil Rails.cache.read(RefreshMcpOauthTokensJob.ambiguous_failure_streak_key(credential.id))

    credential.update_columns(updated_at: 5.hours.ago)
    log_output = capture_rails_logs do
      stub_token_post(token_endpoint_response(502, "Bad Gateway")) { RefreshMcpOauthTokensJob.perform_now }
    end
    assert_not_includes log_output, "ERROR", "the streak restarts after a success"
  end

  test "ambiguous failure logs at error when the streak cannot be counted" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)
    Rails.cache.stubs(:read).raises(Redis::CannotConnectError, "redis down")

    log_output = capture_rails_logs do
      stub_token_post(token_endpoint_response(504, "Gateway Timeout")) { RefreshMcpOauthTokensJob.perform_now }
    end

    assert_includes log_output, "ERROR"
    assert_includes log_output, "streak uncounted"
  end

  test "ambiguous 5xx response on a retry defers to the next scheduled run" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)

    log_output = capture_rails_logs do
      assert_no_enqueued_jobs(only: RefreshMcpOauthTokensJob) do
        stub_token_post(token_endpoint_response(504, "Gateway Timeout")) do
          RefreshMcpOauthTokensJob.perform_now(retry_credential_ids: [ credential.id ], attempt: 1)
        end
      end
    end

    assert_includes log_output, "deferring to the next scheduled run"
    assert_not_includes log_output, "ERROR"
  end

  test "503 on the scheduled run that succeeds on retry clears without an error" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)

    log_output = capture_rails_logs do
      stub_token_post(token_endpoint_response(503, "Service Unavailable")) { RefreshMcpOauthTokensJob.perform_now }
      stub_token_post(token_endpoint_response(200, { access_token: "after-retry", expires_in: 3600 }.to_json)) do
        RefreshMcpOauthTokensJob.perform_now(retry_credential_ids: [ credential.id ], attempt: 1)
      end
    end

    assert_not_includes log_output, "ERROR"
    assert_equal "after-retry", credential.reload.access_token
  end

  test "4xx response stays on the permanent path: no retry, refresh token dropped" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)

    log_output = capture_rails_logs do
      assert_no_enqueued_jobs(only: RefreshMcpOauthTokensJob) do
        stub_token_post(token_endpoint_response(400, "<html>400 Bad Request</html>")) do
          RefreshMcpOauthTokensJob.perform_now
        end
      end
    end

    assert_includes log_output, "Token refresh permanently invalid"
    assert_not_includes log_output, "Transient token endpoint response"
    assert_nil credential.reload.refresh_token
  end

  test "invalid_client refresh failure is treated as permanent (refresh token dropped, valid access token kept)" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)

    failed_response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    failed_response.stubs(:code).returns("401")
    failed_response.stubs(:body).returns({ error: "invalid_client" }.to_json)

    McpOauthService.any_instance.expects(:post_form).once.returns(failed_response)

    log_output = capture_rails_logs do
      RefreshMcpOauthTokensJob.perform_now
    end

    credential.reload
    assert_nil credential.refresh_token
    assert_not credential.can_refresh?
    assert credential.active?, "still-valid access token should be preserved"
    assert_includes log_output, "Token refresh permanently invalid"
    assert_not_includes log_output, "ERROR"
  end

  test "retryable network error (connection never established) logs at info and schedules a retry, not error" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)
    original_token = credential.access_token

    log_output = capture_rails_logs do
      assert_enqueued_with(job: RefreshMcpOauthTokensJob) do
        stub_token_post(->(*) { raise Net::OpenTimeout, "could not connect" }) do
          # Should not raise
          RefreshMcpOauthTokensJob.perform_now
        end
      end
    end

    # Retryable error logged at .info (with retry), never .error
    assert_includes log_output, "Transient error refreshing"
    assert_includes log_output, "(will retry)"
    assert_includes log_output, "scheduling retry 1/#{RefreshMcpOauthTokensJob::MAX_RETRIES}"
    assert_not_includes log_output, "ERROR"

    # Token untouched and still refreshable on the scheduled retry
    credential.reload
    assert_equal original_token, credential.access_token
    assert credential.can_refresh?
  end

  test "ambiguous network error (response lost after send) is not retried and leaves the credential refreshable" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)
    original_token = credential.access_token
    original_refresh_token = credential.refresh_token

    log_output = capture_rails_logs do
      assert_no_enqueued_jobs(only: RefreshMcpOauthTokensJob) do
        stub_token_post(->(*) { raise Net::ReadTimeout, "Connection timed out" }) do
          # Should not raise
          RefreshMcpOauthTokensJob.perform_now
        end
      end
    end

    # No retry scheduled — re-sending the old token risks reuse-detection revocation
    assert_includes log_output, "Ambiguous network failure refreshing"
    assert_includes log_output, "not retrying"
    assert_not_includes log_output, "scheduling retry"
    assert_not_includes log_output, "ERROR"

    # Credential untouched: the next scheduled run attempts a clean refresh
    credential.reload
    assert_equal original_token, credential.access_token
    assert_equal original_refresh_token, credential.refresh_token
    assert credential.can_refresh?
    assert_not credential.requires_reauth?
  end

  test "retryable error on an intermediate retry schedules the next retry at info" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)

    log_output = capture_rails_logs do
      assert_enqueued_with(job: RefreshMcpOauthTokensJob) do
        stub_token_post(->(*) { raise Net::OpenTimeout, "boom" }) do
          RefreshMcpOauthTokensJob.perform_now(retry_credential_ids: [ credential.id ], attempt: 1)
        end
      end
    end

    assert_includes log_output, "scheduling retry 2/#{RefreshMcpOauthTokensJob::MAX_RETRIES}"
    assert_not_includes log_output, "ERROR"
  end

  test "ambiguous error on a retry stops retrying and defers to the next scheduled run" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)

    log_output = capture_rails_logs do
      assert_no_enqueued_jobs(only: RefreshMcpOauthTokensJob) do
        stub_token_post(->(*) { raise Net::ReadTimeout, "boom" }) do
          RefreshMcpOauthTokensJob.perform_now(retry_credential_ids: [ credential.id ], attempt: 1)
        end
      end
    end

    assert_includes log_output, "Ambiguous network failure refreshing"
    assert_includes log_output, "deferring to the next scheduled run"
    assert_not_includes log_output, "scheduling retry"
    assert_not_includes log_output, "ERROR"
  end

  test "retryable error on the final retry escalates to error and stops retrying" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)

    log_output = capture_rails_logs do
      assert_no_enqueued_jobs(only: RefreshMcpOauthTokensJob) do
        stub_token_post(->(*) { raise Net::OpenTimeout, "could not connect" }) do
          RefreshMcpOauthTokensJob.perform_now(
            retry_credential_ids: [ credential.id ],
            attempt: RefreshMcpOauthTokensJob::MAX_RETRIES
          )
        end
      end
    end

    assert_includes log_output, "failed after #{RefreshMcpOauthTokensJob::MAX_RETRIES} retries"
    assert_includes log_output, "ERROR"
  end

  test "unexpected non-transient error logs at error immediately" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)

    log_output = capture_rails_logs do
      assert_no_enqueued_jobs(only: RefreshMcpOauthTokensJob) do
        stub_token_post(->(*) { raise ArgumentError, "unexpected bug" }) do
          RefreshMcpOauthTokensJob.perform_now
        end
      end
    end

    assert_includes log_output, "ERROR"
    assert_includes log_output, "Error refreshing"
  end

  # The cron reads the HOST-GLOBAL stores only — Pi's and Codex's. Claude Code
  # has none: its mcpOAuth map lives in each session's own CLAUDE_CONFIG_DIR
  # (issue #618), and McpOauthCredentialInjector reconciles from THAT store at
  # every spawn and follow-up. A session-less sweep has no Claude file to read,
  # and the one it used to read is a file nothing writes.
  test "adopts a token Pi rotated, even though the cron has no session and no runtime" do
    # The gap this closes: Pi refreshes MCP tokens mid-session exactly as Claude
    # Code does, but the cron used to read only Claude Code's store. So a Pi
    # rotation left the DB stale, and the next cron run burned the rotated-away
    # refresh token against the provider's reuse detection — `invalid_grant`, and
    # the credential dead until a human re-authorized it.
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)

    rotated_expiry = (Time.current + 3.hours).to_i
    entry = JSON.generate(
      "serverUrl" => credential.server_url,
      "tokens" => {
        "accessToken" => "pi-fresh-access",
        "refreshToken" => "pi-rotated-refresh",
        "expiresAt" => rotated_expiry
      },
      "clientInfo" => { "clientId" => credential.client_id }
    )

    # Pi keys its store by the bare server name, not the credential key — the
    # cron has to ask each writer what its own entry is called.
    account = "sha256-#{Digest::SHA256.hexdigest(credential.server_name)}"
    PiMcpCredentialWriter.any_instance.stubs(:keyring_call).returns({ "ok" => true, "found" => false })
    PiMcpCredentialWriter.any_instance.stubs(:keyring_call)
      .with("read", account, timeout: PiMcpCredentialWriter::READ_TIMEOUT_SECONDS)
      .returns({ "ok" => true, "found" => true, "value" => entry })

    McpOauthService.any_instance.expects(:post_form).never

    RefreshMcpOauthTokensJob.perform_now

    credential.reload
    assert_equal "pi-rotated-refresh", credential.refresh_token
    assert_equal "pi-fresh-access", credential.access_token
    assert credential.active?
  end

  private

  def disable_other_refreshable_credentials!(credential)
    McpOauthCredential.where.not(id: credential.id).update_all(refresh_token: nil)
  end

  def token_endpoint_response(status, body)
    klass = Net::HTTPResponse::CODE_TO_OBJ[status.to_s] || Net::HTTPResponse
    response = klass.new("1.1", status.to_s, "")
    response.define_singleton_method(:code) { status.to_s }
    response.define_singleton_method(:body) { body }
    response
  end

  def capture_rails_logs
    original_logger = Rails.logger
    log_output = StringIO.new
    Rails.logger = Logger.new(log_output)

    yield

    log_output.string
  ensure
    Rails.logger = original_logger
  end
end
