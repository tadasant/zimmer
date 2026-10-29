# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class TestflightFeedbackPollJobTest < ActiveSupport::TestCase
  include AppStoreConnectFixtures

  setup do
    TestflightFeedbackPollJob.warned_unconfigured = false
    SecretProviders.stubs(:chain).returns(SecretProviders::Chain.new([ SecretProviders::Env.new({}) ]))
  end

  teardown do
    TestflightFeedbackPollJob.warned_unconfigured = false
  end

  test "without an App Store Connect key it is a no-op that warns once, not once a tick" do
    AppStoreConnect::Client.expects(:new).never
    TestflightFeedbackPoller.expects(:new).never
    Rails.logger.expects(:warn).with(regexp_matches(/App Store Connect key not configured \(TESTFLIGHT_ASC_ISSUER_ID, TESTFLIGHT_ASC_KEY_ID, TESTFLIGHT_ASC_KEY_P8\)/)).once

    assert_no_difference -> { TestflightFeedback.count } do
      3.times { TestflightFeedbackPollJob.new.perform }
    end
  end

  test "with a key it polls" do
    key = OpenSSL::PKey::EC.generate("prime256v1").to_pem
    SecretProviders.stubs(:chain).returns(SecretProviders::Chain.new([ SecretProviders::Env.new(
      "TESTFLIGHT_ASC_ISSUER_ID" => "i", "TESTFLIGHT_ASC_KEY_ID" => "k", "TESTFLIGHT_ASC_KEY_P8" => key
    ) ]))
    TestflightFeedbackPoller.any_instance.expects(:run).returns(TestflightFeedbackPoller::Result.new(created: 0, crash_logs_fetched: 0, crash_logs_pending: 0))

    TestflightFeedbackPollJob.new.perform
  end

  test "an App Store Connect failure is a WARN for the next tick to retry, not a raise" do
    client = FakeClient.new("/v1/apps" => AppStoreConnect::Client::Error.new("App Store Connect answered 500 for /v1/apps", status: 500))
    Rails.logger.expects(:warn).with(regexp_matches(/feedback poll failed: AppStoreConnect::Client::Error/)).once

    assert_nothing_raised { TestflightFeedbackPollJob.new.perform(client: client) }
  end

  test "is a singleton sweep on the pollers queue" do
    assert_equal "pollers", TestflightFeedbackPollJob.new.queue_name
    assert_includes TestflightFeedbackPollJob.ancestors, SingletonSweep
  end
end
