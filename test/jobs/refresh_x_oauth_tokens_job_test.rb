# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class RefreshXOauthTokensJobTest < ActiveJob::TestCase
  include XOauthTestHelpers

  setup do
    XOauthCredential.stubs(:client_id).returns("cid")
    XOauthCredential.stubs(:client_secret).returns("sec")
  end

  def credential(**attrs)
    XOauthCredential.create!({
      account_key: "tadasayy",
      access_token_env_var: "X_OAUTH_ACCESS_TOKEN",
      access_token: "a",
      refresh_token: "r",
      expires_at: 5.minutes.from_now,
      token_endpoint: XOauthCredential::DEFAULT_TOKEN_ENDPOINT
    }.merge(attrs))
  end

  test "refreshes credentials whose access token is expiring" do
    cred = credential(expires_at: 5.minutes.from_now)
    XOauthCredential.any_instance.expects(:refresh!).once.returns(true)
    RefreshXOauthTokensJob.perform_now
    assert cred # present; refresh! asserted via mocha expectation
  end

  test "does not refresh credentials that are not expiring" do
    credential(expires_at: 3.hours.from_now)
    XOauthCredential.any_instance.expects(:refresh!).never
    RefreshXOauthTokensJob.perform_now
  end

  test "does not refresh credentials without a refresh token" do
    credential(refresh_token: nil)
    XOauthCredential.any_instance.expects(:refresh!).never
    RefreshXOauthTokensJob.perform_now
  end

  test "schedules a retry when the token endpoint rate-limits" do
    credential
    XOauthCredential.any_instance.stubs(:refresh!).returns(:rate_limited)
    assert_enqueued_with(job: RefreshXOauthTokensJob) do
      RefreshXOauthTokensJob.perform_now
    end
  end

  test "schedules a retry on a 5xx server error" do
    credential
    XOauthCredential.any_instance.stubs(:refresh!).returns(:server_error)
    assert_enqueued_with(job: RefreshXOauthTokensJob) do
      RefreshXOauthTokensJob.perform_now
    end
  end

  test "does not schedule a retry on a clean success" do
    credential
    XOauthCredential.any_instance.stubs(:refresh!).returns(true)
    assert_no_enqueued_jobs do
      RefreshXOauthTokensJob.perform_now
    end
  end

  test "does not schedule an in-band retry on an ambiguous network failure" do
    credential
    XOauthCredential.any_instance.stubs(:refresh!).raises(Net::ReadTimeout)
    assert_no_enqueued_jobs do
      RefreshXOauthTokensJob.perform_now
    end
  end

  test "schedules a retry on a retryable network failure" do
    credential
    XOauthCredential.any_instance.stubs(:refresh!).raises(Errno::ECONNREFUSED)
    assert_enqueued_with(job: RefreshXOauthTokensJob) do
      RefreshXOauthTokensJob.perform_now
    end
  end

  test "retry pass stops scheduling after MAX_RETRIES" do
    cred = credential
    XOauthCredential.any_instance.stubs(:refresh!).raises(Errno::ECONNREFUSED)
    assert_no_enqueued_jobs do
      RefreshXOauthTokensJob.perform_now(retry_credential_ids: [ cred.id ], attempt: RefreshXOauthTokensJob::MAX_RETRIES)
    end
  end

  # --- the timeout taxonomy (#732) ---
  #
  # Both branches depend on the token request carrying a bound: an unbounded one
  # holds its `default`-queue thread rather than raising either timeout, and the
  # classifications never run. All three drive the real refresh! ->
  # XOauthCredential.post_token_request path (refresh! is NOT stubbed), so the
  # classification is the one production would make. The read-timeout pair gets
  # its timeout from a real silent socket; the connect one cannot (see below).

  test "a hanging token endpoint is classified ambiguous, not retried in-band, and does not block" do
    with_hanging_token_endpoint do |endpoint|
      cred = credential(token_endpoint: endpoint)

      entries = nil
      elapsed = elapsed_seconds do
        with_token_request_timeout(1) do
          entries = capture_log_entries do
            assert_no_enqueued_jobs { RefreshXOauthTokensJob.perform_now }
          end
        end
      end

      # Net::HTTP's default read timeout is 60s and applies per read; 10s of
      # slack proves the bound came from TOKEN_REQUEST_TIMEOUT.
      assert_operator elapsed, :<, 10, "the job blocked on the hanging endpoint instead of timing out"
      assert_includes entries.map(&:last).join("\n"), "Ambiguous network failure"
      assert_includes entries.map(&:last).join("\n"), "Net::ReadTimeout"
      # A read timeout may mean X already consumed the single-use refresh token,
      # so the chain is left untouched for the next scheduled run.
      assert_equal "r", cred.reload.refresh_token
    end
  end

  test "Net::ReadTimeout from the token request lands in AMBIGUOUS and not in RETRYABLE" do
    with_hanging_token_endpoint do |endpoint|
      cred = credential(token_endpoint: endpoint)

      error = nil
      elapsed = elapsed_seconds do
        error = with_token_request_timeout(1) { assert_raises(Net::ReadTimeout) { cred.refresh! } }
      end

      assert_operator elapsed, :<, 10, "the read bound did not apply — this fell back to Net::HTTP's default"
      assert_includes RefreshXOauthTokensJob::AMBIGUOUS_REFRESH_ERRORS, error.class
      assert_not_includes RefreshXOauthTokensJob::RETRYABLE_REFRESH_ERRORS, error.class
    end
  end

  # The connect half of the bound. A connect that never completes is not
  # reproducible from a test socket, so the timeout is raised at the transport
  # while the rest of the path (refresh! -> post_token_request -> the job's
  # rescue clauses) stays real.
  test "a connect timeout is classified retryable and schedules an in-band retry" do
    cred = credential
    Net::HTTP.any_instance.stubs(:request).raises(Net::OpenTimeout)

    entries = capture_log_entries do
      assert_enqueued_with(job: RefreshXOauthTokensJob) { RefreshXOauthTokensJob.perform_now }
    end

    assert_includes entries.map(&:last).join("\n"), "Transient error refreshing"
    # Connection never established -> the single-use refresh token was not spent.
    assert_equal "r", cred.reload.refresh_token
  end
end
