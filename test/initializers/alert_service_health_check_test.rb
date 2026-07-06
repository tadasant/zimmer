# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class AlertServiceHealthCheckTest < ActiveSupport::TestCase
  # Tests for AlertService.missing_configuration_details, which the
  # boot-time health check initializer calls to produce actionable
  # diagnostic messages.

  setup do
    AlertService.reset!
  end

  teardown do
    AlertService.reset!
  end

  test "missing_configuration_details includes Slack token when not configured" do
    SlackService.stubs(:configured?).returns(false)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    details = AlertService.missing_configuration_details
    assert_includes details, "Slack token missing"
    assert_not_includes details, "ENG_ALERTS_SLACK_CHANNEL_ID missing"
  end

  test "missing_configuration_details includes channel ID when missing" do
    SlackService.stubs(:configured?).returns(true)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns(nil)
    ENV.stubs(:[]).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns(nil)

    details = AlertService.missing_configuration_details
    assert_not_includes details, "Slack token missing"
    assert_includes details, "ENG_ALERTS_SLACK_CHANNEL_ID missing"
  end

  test "missing_configuration_details returns both issues when nothing is configured" do
    SlackService.stubs(:configured?).returns(false)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns(nil)
    ENV.stubs(:[]).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns(nil)

    details = AlertService.missing_configuration_details
    assert_includes details, "Slack token missing"
    assert_includes details, "ENG_ALERTS_SLACK_CHANNEL_ID missing"
  end

  test "missing_configuration_details returns empty array when fully configured" do
    SlackService.stubs(:configured?).returns(true)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C0A6HS92LM8")

    details = AlertService.missing_configuration_details
    assert_empty details
  end
end
