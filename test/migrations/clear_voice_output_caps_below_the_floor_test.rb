# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261104200000_clear_voice_output_caps_below_the_floor")

# Every writer clamps to the floor from this deploy on, but a value stored before it
# was never checked against it: the 180 the live model left behind would go on
# truncating every reply and tool call of every call.
class ClearVoiceOutputCapsBelowTheFloorTest < ActiveSupport::TestCase
  setup { @migration = ClearVoiceOutputCapsBelowTheFloor.new }

  def migrate
    ActiveRecord::Migration.suppress_messages { @migration.up }
  end

  def stored(cap) = LiveSetting.editable.tap { |setting| setting.update_columns(voice_max_output_tokens: cap) }

  test "a cap under the floor goes back to no cap, in the history, and the next call runs uncapped" do
    stored(180)

    migrate

    assert_nil LiveSetting.current.voice_max_output_tokens
    assert_not LiveSetting.current.overridden?(:voice_max_output_tokens)
    change = LiveSettingChange.sole
    assert_equal [ 180, nil ], change.changeset["voice_max_output_tokens"]
    assert_equal "agent", change.actor_kind
    client = LiveConversationHelpers::FakeOpenai.new
    LiveConversations::RealtimeSession.mint(create_live_conversation(mode: "voice"), client: client)
    assert_nil client.secret_requests.sole.dig("session", "max_output_tokens")
  end

  test "a cap a person could still have chosen is left alone, and a second run does nothing" do
    stored(1_024)

    2.times { migrate }

    assert_equal 1_024, LiveSetting.current.voice_max_output_tokens
    assert_empty LiveSettingChange.all
  end

  test "no row is nothing to do" do
    assert_nothing_raised { migrate }
    assert_empty LiveSetting.all
  end
end
