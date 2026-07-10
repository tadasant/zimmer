# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class RefreshXOauthTokensJobTest < ActiveJob::TestCase
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
end
