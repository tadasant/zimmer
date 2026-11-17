# frozen_string_literal: true

require "test_helper"

class LiveConversations::SpendGuardTest < ActiveSupport::TestCase
  def spend(engine, seconds, conversation: nil, at: Time.current)
    LiveUsageEvent.record!(engine: engine, operation: "voice_session", vendor: "openai_live", model: "gpt-live-1",
                           seconds: seconds, live_conversation: conversation, occurred_at: at)
  end

  test "the conservative defaults: $2 a conversation, $10 a day per engine" do
    check = LiveConversations::SpendGuard.check(engine: "gpt_live_claude", conversation: create_live_conversation)

    assert_equal 2.0, check.conversation_cap
    assert_equal 10.0, check.daily_cap
    assert_not check.blocked?
    assert_not check.warn?
  end

  test "the daily cap counts every conversation on that engine today, and nothing else" do
    conversation = create_live_conversation
    LiveSetting.editable.update!(voice_engine_daily_cap_usd: 1.0)
    spend("gpt_live_claude", 60 * 10) # $0.50, no conversation
    spend("gpt_live_claude", 60 * 10, at: 2.days.ago) # yesterday's: not today
    spend("livekit_claude", 60 * 100) # another engine's
    assert_not LiveConversations::SpendGuard.check(engine: "gpt_live_claude", conversation: conversation).warn?

    spend("gpt_live_claude", 60 * 7) # $0.85 today
    check = LiveConversations::SpendGuard.check(engine: "gpt_live_claude", conversation: conversation)
    assert check.warn?
    assert_in_delta 0.85, check.daily_spend, 0.0001

    spend("gpt_live_claude", 60 * 3)
    check = LiveConversations::SpendGuard.check(engine: "gpt_live_claude", conversation: conversation)
    assert check.blocked?
    assert_match(/daily cap \(\$1\.00 of \$1\.00 today\)/, check.reason)
  end

  def claude(basis, conversation:, input_tokens: 1_000_000)
    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "delegation", vendor: "anthropic", model: "claude-opus-5-5",
                           input_tokens: input_tokens, live_conversation: conversation, billing_basis: basis)
  end

  test "Claude on the subscription does not trip a cap, however much its list price is" do
    conversation = create_live_conversation
    claude("subscription", conversation: conversation) # $4.00 at Opus list price

    check = LiveConversations::SpendGuard.check(engine: "gpt_live_claude", conversation: conversation)
    assert_not check.blocked?
    assert_not check.warn?
    assert_equal 0.0, check.conversation_spend
    assert_equal 0.0, check.daily_spend
    assert_operator LiveUsageEvent.sole.cost_usd.to_f, :>, 2.0, "the list price is still on the ledger"
  end

  test "metered OpenAI spend trips the per-conversation cap, and the reason names the metered figure" do
    conversation = create_live_conversation
    claude("subscription", conversation: conversation)
    spend("gpt_live_claude", 60 * 42, conversation: conversation) # $2.10 of GPT-Live seconds

    check = LiveConversations::SpendGuard.check(engine: "gpt_live_claude", conversation: conversation)
    assert check.blocked?
    assert_in_delta 2.10, check.conversation_spend, 0.0001
    assert_match(/per-conversation cap \(\$2\.10 of \$2\.00\)/, check.reason)
  end

  test "Claude billed per token on an API key counts toward the caps" do
    conversation = create_live_conversation
    row = claude("metered", conversation: conversation) # $4.00 at Opus list price, billed

    check = LiveConversations::SpendGuard.check(engine: "gpt_live_claude", conversation: conversation)
    assert check.blocked?
    assert_operator row.cost_usd.to_f, :>, 2.0
    assert_in_delta row.cost_usd.to_f, check.conversation_spend, 0.0001
  end
end
