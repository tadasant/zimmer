# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class RefreshMcpOauthTokensJobTest < ActiveJob::TestCase
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

    Net::HTTP.stub(:post_form, successful_response) do
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

    Net::HTTP.stub(:post_form, ->(*) { raise "Should not attempt refresh" }) do
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
    Net::HTTP.expects(:post_form).never

    RefreshMcpOauthTokensJob.perform_now

    # Token left untouched — proactive rotation was skipped
    credential.reload
    assert_equal "soon-expiring-access-token", credential.access_token
    assert credential.can_refresh?
  end

  test "skips credentials without refresh_token" do
    credential = mcp_oauth_credentials(:expired)
    # expired fixture has no refresh_token

    Net::HTTP.stub(:post_form, ->(*) { raise "Should not attempt refresh" }) do
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

    Net::HTTP.expects(:post_form).once.returns(failed_response)

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
    Net::HTTP.expects(:post_form).never
    RefreshMcpOauthTokensJob.perform_now
  end

  test "transient refresh failure remains alertable and refreshable" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)
    original_token = credential.access_token
    original_refresh_token = credential.refresh_token

    failed_response = Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable")
    failed_response.stubs(:code).returns("503")
    failed_response.stubs(:body).returns({ error: "temporarily_unavailable" }.to_json)

    log_output = capture_rails_logs do
      Net::HTTP.stub(:post_form, failed_response) do
        # Should not raise
        RefreshMcpOauthTokensJob.perform_now
      end
    end

    credential.reload
    assert_equal original_token, credential.access_token
    assert_equal original_refresh_token, credential.refresh_token
    assert credential.can_refresh?
    assert_not credential.requires_reauth?
    assert_includes log_output, "ERROR"
    assert_includes log_output, "[McpOauthCredential] Token refresh failed: 503"
  end

  test "invalid_client refresh failure is treated as permanent (refresh token dropped, valid access token kept)" do
    credential = mcp_oauth_credentials(:expiring_soon)
    disable_other_refreshable_credentials!(credential)

    failed_response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    failed_response.stubs(:code).returns("401")
    failed_response.stubs(:body).returns({ error: "invalid_client" }.to_json)

    Net::HTTP.expects(:post_form).once.returns(failed_response)

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
        Net::HTTP.stub(:post_form, ->(*) { raise Net::OpenTimeout, "could not connect" }) do
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
        Net::HTTP.stub(:post_form, ->(*) { raise Net::ReadTimeout, "Connection timed out" }) do
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
        Net::HTTP.stub(:post_form, ->(*) { raise Net::OpenTimeout, "boom" }) do
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
        Net::HTTP.stub(:post_form, ->(*) { raise Net::ReadTimeout, "boom" }) do
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
        Net::HTTP.stub(:post_form, ->(*) { raise Net::OpenTimeout, "could not connect" }) do
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
        Net::HTTP.stub(:post_form, ->(*) { raise ArgumentError, "unexpected bug" }) do
          RefreshMcpOauthTokensJob.perform_now
        end
      end
    end

    assert_includes log_output, "ERROR"
    assert_includes log_output, "Error refreshing"
  end

  private

  def disable_other_refreshable_credentials!(credential)
    McpOauthCredential.where.not(id: credential.id).update_all(refresh_token: nil)
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
