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
end
