# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class AlertServiceTest < ActiveSupport::TestCase
  setup do
    AlertService.reset!
    # Use a memory store for dedup tests (test env uses NullStore by default)
    @original_cache = Rails.cache
    @memory_cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache = @memory_cache
  end

  teardown do
    AlertService.reset!
    Rails.cache = @original_cache
  end

  # === configured? ===

  test "configured? returns false when Slack is not configured" do
    SlackService.stubs(:configured?).returns(false)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    assert_not AlertService.configured?
  end

  test "configured? returns false when channel ID is missing" do
    SlackService.stubs(:configured?).returns(true)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns(nil)
    ENV.stubs(:[]).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns(nil)

    assert_not AlertService.configured?
  end

  test "configured? returns true when both Slack and channel ID are available" do
    SlackService.stubs(:configured?).returns(true)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    assert AlertService.configured?
  end

  test "configured? returns true when channel ID comes from ENV" do
    SlackService.stubs(:configured?).returns(true)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns(nil)
    ENV.stubs(:[]).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    assert AlertService.configured?
  end

  # === raise_alert ===

  test "raise_alert sends message to Slack when configured" do
    mock_client = mock("slack_client")
    mock_client.expects(:chat_postMessage).with do |args|
      args[:channel] == "C123" &&
        args[:text].is_a?(String) && args[:text].include?("Test alert") &&
        args[:blocks].is_a?(Array)
    end.returns(true)

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    result = AlertService.raise_alert("Test alert", details: "Something went wrong", source: "TestJob")
    assert result
  end

  test "raise_alert returns false when not configured" do
    SlackService.stubs(:configured?).returns(false)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns(nil)
    ENV.stubs(:[]).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns(nil)

    result = AlertService.raise_alert("Test alert")
    assert_not result
  end

  test "raise_alert returns false on Slack API error" do
    mock_client = mock("slack_client")
    mock_client.expects(:chat_postMessage).raises(Slack::Web::Api::Errors::SlackError.new("channel_not_found"))

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    result = AlertService.raise_alert("Test alert")
    assert_not result
  end

  # === Deduplication ===

  test "raise_alert suppresses duplicate alerts within dedup window" do
    mock_client = mock("slack_client")
    # Should only be called once
    mock_client.expects(:chat_postMessage).once.returns(true)

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    # First call should send
    result1 = AlertService.raise_alert("Same alert", source: "TestJob")
    assert result1

    # Second call with same title + source should be suppressed
    result2 = AlertService.raise_alert("Same alert", source: "TestJob")
    assert_not result2
  end

  test "raise_alert allows different alerts through" do
    mock_client = mock("slack_client")
    mock_client.expects(:chat_postMessage).twice.returns(true)

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    result1 = AlertService.raise_alert("Alert A", source: "TestJob")
    assert result1

    result2 = AlertService.raise_alert("Alert B", source: "TestJob")
    assert result2
  end

  test "raise_alert uses custom dedup_key for deduplication" do
    mock_client = mock("slack_client")
    mock_client.expects(:chat_postMessage).once.returns(true)

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    result1 = AlertService.raise_alert("CI failure", dedup_key: "ci_run_123")
    assert result1

    result2 = AlertService.raise_alert("CI failure", dedup_key: "ci_run_123")
    assert_not result2
  end

  test "raise_alert sends again after cache expires" do
    mock_client = mock("slack_client")
    mock_client.expects(:chat_postMessage).twice.returns(true)

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    # First call
    AlertService.raise_alert("Test alert", source: "TestJob")

    # Clear cache to simulate expiration
    Rails.cache.clear

    # Should send again
    result = AlertService.raise_alert("Test alert", source: "TestJob")
    assert result
  end

  # === Slack block formatting ===

  test "raise_alert builds well-formatted Slack blocks" do
    mock_client = mock("slack_client")
    blocks_sent = nil
    mock_client.expects(:chat_postMessage).with do |args|
      blocks_sent = args[:blocks]
      true
    end.returns(true)

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    AlertService.raise_alert("Test title", details: "Error details", source: "TestJob")

    assert_not_nil blocks_sent
    assert_equal 3, blocks_sent.length

    # Header
    assert_equal "header", blocks_sent[0][:type]
    assert_includes blocks_sent[0][:text][:text], "Test title"

    # Details section
    assert_equal "section", blocks_sent[1][:type]
    assert_equal "Error details", blocks_sent[1][:text][:text]

    # Context
    assert_equal "context", blocks_sent[2][:type]
    source_element = blocks_sent[2][:elements].find { |e| e[:text].include?("Source") }
    assert_not_nil source_element
    assert_includes source_element[:text], "TestJob"
  end

  # === Fallback text field (regression: block-blind consumers) ===
  #
  # Slack's `text:` field is what push notifications, accessibility tools, and
  # block-blind API consumers (e.g., the slack-workspace MCP, which only
  # exposes `text:`) see. If we set it to just the title, those consumers
  # only see "Schedule trigger session creation failed" with no diagnostic
  # body, even though the rich blocks contain everything. The fix is to
  # combine title + source + details into the fallback text.

  test "raise_alert text: field includes diagnostic details (block-blind consumers)" do
    mock_client = mock("slack_client")
    text_sent = nil
    mock_client.expects(:chat_postMessage).with do |args|
      text_sent = args[:text]
      true
    end.returns(true)

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    AlertService.raise_alert(
      "Schedule trigger session creation failed",
      details: "Condition 42 on trigger 'deploy-notify' (ID: 7) failed: timeout",
      source: "ScheduleTriggerJob"
    )

    assert_not_nil text_sent
    # Title still leads (preserves push-notification preview behavior)
    assert text_sent.start_with?("Schedule trigger session creation failed"), "text: should start with the title"
    # Source and details must be included so block-blind consumers see them
    assert_includes text_sent, "ScheduleTriggerJob"
    assert_includes text_sent, "Condition 42"
    assert_includes text_sent, "deploy-notify"
    assert_includes text_sent, "timeout"
  end

  test "raise_alert text: field falls back to title when no details or source" do
    mock_client = mock("slack_client")
    text_sent = nil
    mock_client.expects(:chat_postMessage).with do |args|
      text_sent = args[:text]
      true
    end.returns(true)

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    AlertService.raise_alert("Title only")

    assert_equal "Title only", text_sent
  end

  test "raise_alert text: field truncates very long bodies" do
    mock_client = mock("slack_client")
    text_sent = nil
    mock_client.expects(:chat_postMessage).with do |args|
      text_sent = args[:text]
      true
    end.returns(true)

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    huge_details = "X" * 10_000
    AlertService.raise_alert("Big alert", details: huge_details, source: "Job")

    assert_not_nil text_sent
    # Truncate keeps fallback text bounded for sane push-notification UX
    assert_operator text_sent.length, :<=, 3500
  end

  test "raise_alert omits details section when details is nil" do
    mock_client = mock("slack_client")
    blocks_sent = nil
    mock_client.expects(:chat_postMessage).with do |args|
      blocks_sent = args[:blocks]
      true
    end.returns(true)

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    AlertService.raise_alert("Title only")

    # Should have header + context (no details section)
    assert_equal 2, blocks_sent.length
    assert_equal "header", blocks_sent[0][:type]
    assert_equal "context", blocks_sent[1][:type]
  end

  # === Graceful degradation ===

  test "raise_alert does not crash when Rails cache is unavailable" do
    # Simulate cache failure
    Rails.cache.stubs(:exist?).raises(Redis::CannotConnectError.new("Connection refused"))
    Rails.cache.stubs(:write).raises(Redis::CannotConnectError.new("Connection refused"))

    mock_client = mock("slack_client")
    mock_client.expects(:chat_postMessage).returns(true)

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    # Should still send the alert even if cache is broken
    result = AlertService.raise_alert("Test alert")
    assert result
  end

  test "raise_alert does not crash on unexpected errors" do
    SlackService.stubs(:configured?).raises(StandardError.new("unexpected"))
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    result = AlertService.raise_alert("Test alert")
    assert_not result
  end
end
