# frozen_string_literal: true

# Every 15 minutes, pull new TestFlight crash and screenshot feedback for the
# Zimmer iOS app out of App Store Connect (TestflightFeedbackPoller).
#
# Without an App Store Connect key (AppStoreConnect::Client::VARIABLES) this is a
# no-op that says so once per process rather than once a tick: an absent key is
# a supported configuration, not a fault.
#
# A failed pass logs a WARN and is retried by the next tick. It does not page:
# App Store Connect being slow or briefly down is not something to wake anyone
# for, and a pass that fails every time is visible in the log stream and as
# crashes that never show up in `get_testflight_crashes`.
class TestflightFeedbackPollJob < ApplicationJob
  queue_as :pollers
  include SingletonSweep

  class << self
    attr_accessor :warned_unconfigured
  end

  def perform
    client = build_client
    return unless client

    result = TestflightFeedbackPoller.new(client: client).run
    return if result.created.zero? && result.crash_logs_fetched.zero?

    Rails.logger.info(
      "[testflight] #{result.created} new submission(s), #{result.crash_logs_fetched} crash log(s) fetched, " \
      "#{result.crash_logs_pending} still pending"
    )
  rescue AppStoreConnect::Client::Error, ParameterStore::AuthError, ParameterStore::StoreError, OpenSSL::PKey::PKeyError, JWT::EncodeError => e
    Rails.logger.warn("[testflight] feedback poll failed: #{e.class}: #{e.message}")
  end

  private

  def build_client
    credentials = AppStoreConnect::Client.credentials
    if credentials.nil?
      unless self.class.warned_unconfigured
        self.class.warned_unconfigured = true
        Rails.logger.warn(
          "[testflight] App Store Connect key not configured (#{AppStoreConnect::Client::VARIABLES.join(', ')}); " \
          "TestFlight crash feedback is not being collected"
        )
      end
      return nil
    end

    AppStoreConnect::Client.new(credentials: credentials)
  end
end
