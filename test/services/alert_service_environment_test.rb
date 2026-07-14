# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The environment allowlist that keeps non-production processes from paging the
# real #alerts Slack channel.
#
# This is the Slack-path twin of test/initializers/sentry_test.rb. Zimmer runs its
# agent sessions INSIDE the production container, so an agent shelling out to
# `RAILS_ENV=test bin/rails test` in its repo clone inherits production's
# SLACK_BOT_TOKEN and ENG_ALERTS_SLACK_CHANNEL_ID. A token/channel check alone
# therefore proves nothing about which environment is talking: it is satisfied in
# test exactly as it is in production. Only Rails.env can tell them apart.
#
# Deliberately does NOT force alerting_enabled? on (as AlertServiceTest does) --
# these tests exist to assert the guard actually holds under a fully-configured
# Slack, which is precisely the state that produced the incident.
class AlertServiceEnvironmentTest < ActiveSupport::TestCase
  setup do
    AlertService.reset!
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    AlertService.reset!
    Rails.cache = @original_cache
  end

  # Slack fully configured, exactly as it is inside the production container.
  # The client must never be asked to post.
  def with_configured_slack
    client = mock("slack_client")
    client.expects(:chat_postMessage).never

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C_PROD_ALERTS")

    yield client
  end

  test "only production and staging may page the alert channel" do
    assert_equal %w[production staging], AlertService::ENABLED_ENVIRONMENTS

    # Restored explicitly rather than left to Mocha, which unstubs only after the
    # Rails teardown chain has already run against a faked Rails.env.
    original = Rails.env
    begin
      %w[production staging].each do |env|
        Rails.env = env
        assert AlertService.alerting_enabled?, "#{env} should be allowed to alert"
      end

      %w[test development ad-hoc].each do |env|
        Rails.env = env
        assert_not AlertService.alerting_enabled?, "#{env} must not be allowed to alert"
      end
    ensure
      Rails.env = original
    end
  end

  # The verbatim alert from the incident. The job that emitted it lives on an unmerged
  # branch, which is the point: a poller that was never deployed still paged the
  # production channel, because its TEST run had production's Slack token. The ids are
  # FixtureSet.identify hashes -- this alert is made entirely of fixture data.
  test "raise_alert does not post to Slack from the test environment even when Slack is configured" do
    with_configured_slack do
      assert_not AlertService.raise_alert(
        "GitHub trigger poller error",
        details: "Condition 949208330 on trigger 'Ready-to-merge PR gate' (ID: 887723230) failed:\nboom",
        source: "GithubTriggerPollerJob",
        dedup_key: "github_trigger_condition_949208330"
      )
    end
  end

  # AlertBatcher.flush! calls AlertService.emit directly, bypassing raise_alert.
  # Guarding only raise_alert would leave this second door into Slack wide open.
  test "emit does not post to Slack from the test environment even when Slack is configured" do
    with_configured_slack do
      assert_not AlertService.emit(
        "Batched alert",
        details: "flushed from a batch",
        source: "TestJob",
        dedup_key: "batched"
      )
    end
  end

  test "a batched run of per-condition failures pages nobody from the test environment" do
    with_configured_slack do
      AlertBatcher.with_batch do
        3.times do |i|
          AlertService.raise_alert(
            "GitHub trigger poller error",
            details: "Condition #{i} failed:\nwrong number of arguments (given 2, expected 3)",
            source: "GithubTriggerPollerJob",
            dedup_key: "github_trigger_condition_#{i}"
          )
        end
      end
    end
  end

  test "a suppressed alert is not marked as sent, so production still delivers it" do
    # The guard must decline BEFORE the dedup cache is written. Marking a
    # dropped alert as "sent" would let a test run poison the dedup window and
    # silence the same alert in production for an hour.
    with_configured_slack do
      AlertService.raise_alert("Quiet alert", source: "TestJob", dedup_key: "quiet")
    end

    assert_not Rails.cache.exist?("#{AlertService::CACHE_PREFIX}quiet"),
               "test-env alert must not consume the production dedup window"
  end
end
