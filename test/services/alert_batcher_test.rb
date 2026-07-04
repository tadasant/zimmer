# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class AlertBatcherTest < ActiveSupport::TestCase
  setup do
    AlertService.reset!
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    # Every test uses a configured AlertService → fresh Slack mock per test
    @mock_client = mock("slack_client")
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:client).returns(@mock_client)
    SecretsLoader.stubs(:get).with("ENG_ALERTS_SLACK_CHANNEL_ID").returns("C123")
  end

  teardown do
    AlertService.reset!
    Rails.cache = @original_cache
    # Defensive: ensure no leaked thread-local state between tests
    Thread.current[:alert_batch] = nil
  end

  # === open? ===

  test "open? returns false outside of a batch" do
    assert_not AlertBatcher.open?
  end

  test "open? returns true inside of a batch" do
    was_open = nil
    AlertBatcher.with_batch { was_open = AlertBatcher.open? }
    assert_equal true, was_open
    assert_not AlertBatcher.open?, "scope should close after block"
  end

  # === Collapsing bursts ===

  test "with_batch collapses N alerts with the same title+source into one Slack message" do
    # Expect a single aggregated Slack post even though we call raise_alert 3 times
    captured = nil
    @mock_client.expects(:chat_postMessage).once.with do |args|
      captured = args
      true
    end.returns(true)

    AlertBatcher.with_batch do
      3.times do |i|
        AlertService.raise_alert(
          "Trigger self-healed: stale MCP server(s) removed",
          details: "Trigger ##{i + 1} removed server 'foo'",
          source: "Trigger#create_session!",
          dedup_key: "trigger_stale_mcp_#{i + 1}"
        )
      end
    end

    assert_not_nil captured, "expected a Slack message to be posted"
    assert_includes captured[:text], "×3", "aggregated title should include count"
    details_block = captured[:blocks].find { |b| b[:type] == "section" }
    assert_includes details_block[:text][:text], "3 occurrences in this run"
    assert_includes details_block[:text][:text], "Trigger #1 removed server 'foo'"
    assert_includes details_block[:text][:text], "Trigger #3 removed server 'foo'"
  end

  test "with_batch preserves single-alert behavior when only one alert in group" do
    @mock_client.expects(:chat_postMessage).once.with do |args|
      # Title leads the fallback text (no ×N suffix for a single event), and
      # the section block carries the original details verbatim.
      args[:text].start_with?("Some isolated error") &&
        args[:blocks].find { |b| b[:type] == "section" }&.dig(:text, :text) == "the details"
    end.returns(true)

    AlertBatcher.with_batch do
      AlertService.raise_alert(
        "Some isolated error",
        details: "the details",
        source: "SomeJob",
        dedup_key: "alone"
      )
    end
  end

  test "with_batch emits separate messages for different (title, source) groups" do
    # Expect exactly 2 posts: one per (title, source) group
    @mock_client.expects(:chat_postMessage).twice.returns(true)

    AlertBatcher.with_batch do
      AlertService.raise_alert("Stale MCP removed", details: "d1", source: "JobA", dedup_key: "a1")
      AlertService.raise_alert("Stale MCP removed", details: "d2", source: "JobA", dedup_key: "a2")
      AlertService.raise_alert("Stale skill removed", details: "d3", source: "JobA", dedup_key: "b1")
      AlertService.raise_alert("Stale skill removed", details: "d4", source: "JobA", dedup_key: "b2")
    end
  end

  # === Dedup interplay ===

  test "aggregated messages respect dedup window by burst signature" do
    # Same burst signature (same set of dedup_keys) in two back-to-back batches:
    # the second aggregated message should be suppressed.
    @mock_client.expects(:chat_postMessage).once.returns(true)

    2.times do
      AlertBatcher.with_batch do
        AlertService.raise_alert("T", details: "x", source: "S", dedup_key: "k1")
        AlertService.raise_alert("T", details: "y", source: "S", dedup_key: "k2")
      end
    end
  end

  test "different burst signatures produce separate aggregated messages" do
    # Different sets of dedup_keys → different digest → different dedup_key → both fire
    @mock_client.expects(:chat_postMessage).twice.returns(true)

    AlertBatcher.with_batch do
      AlertService.raise_alert("T", details: "x", source: "S", dedup_key: "k1")
      AlertService.raise_alert("T", details: "y", source: "S", dedup_key: "k2")
    end
    AlertBatcher.with_batch do
      AlertService.raise_alert("T", details: "x", source: "S", dedup_key: "k3")
      AlertService.raise_alert("T", details: "y", source: "S", dedup_key: "k4")
    end
  end

  # === Nesting ===

  test "nested with_batch reuses the outer batch and flushes only once" do
    # Two alerts: one inside nested block, one outside. Both should collapse
    # together, producing a single aggregated message at the outer flush.
    @mock_client.expects(:chat_postMessage).once.with do |args|
      args[:text].include?("×2")
    end.returns(true)

    AlertBatcher.with_batch do
      AlertService.raise_alert("T", details: "d1", source: "S", dedup_key: "k1")
      AlertBatcher.with_batch do
        AlertService.raise_alert("T", details: "d2", source: "S", dedup_key: "k2")
        assert AlertBatcher.open?
      end
      # Inner block exit does NOT flush — outer batch still open
      assert AlertBatcher.open?
    end
  end

  test "with_batch flushes even when the block raises" do
    @mock_client.expects(:chat_postMessage).once.returns(true)

    assert_raises(RuntimeError) do
      AlertBatcher.with_batch do
        AlertService.raise_alert("T", details: "d", source: "S", dedup_key: "k")
        raise "boom"
      end
    end
    # Cleanup: thread-local state should be cleared even after raise
    assert_not AlertBatcher.open?
  end

  # === Truncation ===

  test "aggregated details are truncated to stay under Slack's section limit" do
    captured = nil
    @mock_client.expects(:chat_postMessage).once.with do |args|
      captured = args
      true
    end.returns(true)

    AlertBatcher.with_batch do
      # 50 alerts × ~200 chars each → ~10k chars before truncation
      50.times do |i|
        AlertService.raise_alert(
          "Stale MCP removed",
          details: "a" * 200,
          source: "S",
          dedup_key: "k#{i}"
        )
      end
    end

    details_block = captured[:blocks].find { |b| b[:type] == "section" }
    assert_operator details_block[:text][:text].length, :<=, 3000,
      "aggregated details must fit Slack's 3000-char section limit"
  end

  # === Passthrough when no batch is open ===

  test "raise_alert behaves normally when no batch is open" do
    @mock_client.expects(:chat_postMessage).once.returns(true)
    AlertService.raise_alert("Unbatched", details: "d", source: "S")
  end

  # === Isolation between groups on flush ===

  test "flush emits remaining groups even if an earlier group's Slack post raises" do
    # Two distinct (title, source) groups → two AlertService.emit calls on flush.
    # Simulate the first group's Slack post blowing up (e.g., API 5xx) and assert
    # the second group still emits. Without per-group rescue the second would be
    # silently dropped.
    AlertService.expects(:emit).with("A", anything).raises(RuntimeError, "slack 500")
    AlertService.expects(:emit).with("B", anything).once

    AlertBatcher.with_batch do
      AlertService.raise_alert("A", details: "da", source: "SomeJob", dedup_key: "a1")
      AlertService.raise_alert("B", details: "db", source: "SomeJob", dedup_key: "b1")
    end
  end
end
