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

  # === Log snippets (error:) ===
  #
  # An alert whose body is only hand-written prose makes a reader open the logs
  # to learn anything. `error:` carries the real failure into Slack — and has to
  # reach BOTH the blocks and the block-blind `text:` field.

  def capture_post
    payload = {}
    mock_client = mock("slack_client")
    mock_client.expects(:chat_postMessage).with do |args|
      payload.merge!(args)
      true
    end.returns(true)

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")
    payload
  end

  def boom(message: "connection reset by peer")
    error = Faraday::ConnectionFailed.new(message)
    error.set_backtrace([
      "/usr/local/bundle/gems/net-http-0.4.1/lib/net/http.rb:1611:in 'connect'",
      "#{Rails.root}/app/services/slack_service.rb:214:in 'get_channel_history'",
      "#{Rails.root}/app/jobs/slack_trigger_poller_job.rb:126:in 'perform'"
    ])
    error
  end

  test "raise_alert renders the exception as a fenced snippet block" do
    payload = capture_post

    AlertService.raise_alert("Poller error", details: "Condition 42 failed.", source: "SlackTriggerPollerJob", error: boom)

    snippet_block = payload[:blocks].find { |b| b[:text].is_a?(Hash) && b[:text][:text].to_s.start_with?("```") }
    assert_not_nil snippet_block, "expected a fenced code block carrying the snippet"
    assert_equal "section", snippet_block[:type]
    assert_includes snippet_block[:text][:text], "Faraday::ConnectionFailed: connection reset by peer"
    assert_includes snippet_block[:text][:text], "app/jobs/slack_trigger_poller_job.rb:126"
  end

  test "raise_alert puts the snippet in text: too (block-blind consumers)" do
    payload = capture_post

    AlertService.raise_alert("Poller error", details: "Condition 42 failed.", source: "SlackTriggerPollerJob", error: boom)

    assert_includes payload[:text], "Faraday::ConnectionFailed: connection reset by peer"
    assert_includes payload[:text], "app/services/slack_service.rb:214"
  end

  test "raise_alert accepts a raw log string as error:" do
    payload = capture_post

    AlertService.raise_alert("Gate unreachable", source: "Job", error: "Errno::ECONNREFUSED: Connection refused")

    assert_includes payload[:text], "Errno::ECONNREFUSED: Connection refused"
  end

  test "raise_alert emits no snippet block when there is no error" do
    payload = capture_post

    AlertService.raise_alert("Plain alert", details: "just prose", source: "Job")

    assert_equal 3, payload[:blocks].length
    assert_not_includes payload[:text], "```"
  end

  test "raise_alert redacts secrets in the snippet" do
    payload = capture_post
    # Assembled rather than written as a literal: it is synthetic, but a literal
    # one trips GitHub's push protection.
    token = "xox" + "b-1234567890-ABCDEFGHIJKLMNOP"

    AlertService.raise_alert("Auth failure", source: "Job", error: "posting with token #{token} failed")

    assert_not_includes payload[:text], token
    assert_includes payload[:text], "[REDACTED]"
  end

  test "raise_alert keeps the snippet whole in text: even when details are huge" do
    payload = capture_post

    AlertService.raise_alert("Big alert", details: "X" * 10_000, source: "Job", error: boom(message: "the needle"))

    assert_operator payload[:text].length, :<=, AlertService::FALLBACK_TEXT_MAX_CHARS
    # The snippet is the highest-signal part: the prose gets cut, not it.
    assert_includes payload[:text], "the needle"
    assert_includes payload[:text], "app/jobs/slack_trigger_poller_job.rb:126"
  end

  test "snippet block stays within Slack's section limit for a pathological error" do
    payload = capture_post

    huge = StandardError.new("x" * 50_000)
    huge.set_backtrace(Array.new(500) { |i| "#{Rails.root}/app/services/deep.rb:#{i}:in 'step'" })
    AlertService.raise_alert("Huge", source: "Job", error: huge)

    payload[:blocks].each do |block|
      next unless block[:text].is_a?(Hash)

      assert_operator block[:text][:text].length, :<, 3000, "every section must stay under Slack's 3000-char limit"
    end
  end

  # === Dedup stability (the flood hazard) ===
  #
  # Snippet content varies per occurrence — line numbers, timestamps, object
  # addresses. If any of it reached the dedup key, the hourly throttle would
  # stop throttling and one broken poller would fill the channel.

  test "differing snippets do not defeat deduplication" do
    mock_client = mock("slack_client")
    mock_client.expects(:chat_postMessage).once.returns(true)

    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")

    first = AlertService.raise_alert("Poller error", source: "Job", error: boom(message: "attempt at 10:00:01 <0x00007f9>"))
    second = AlertService.raise_alert("Poller error", source: "Job", error: boom(message: "attempt at 10:00:02 <0x00007fa>"))

    assert first, "first alert should send"
    assert_not second, "second alert should be suppressed despite a different snippet"
  end

  test "an alert with a snippet dedups identically to one without" do
    expected_key = AlertService.send(:default_dedup_key, "Poller error", "Job")
    AlertService.stubs(:post_to_slack).returns(true)

    AlertService.raise_alert("Poller error", source: "Job", error: boom)

    assert Rails.cache.exist?("#{AlertService::CACHE_PREFIX}#{expected_key}"),
           "the dedup key must be derived from title + source only"
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
