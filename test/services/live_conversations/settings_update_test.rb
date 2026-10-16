# frozen_string_literal: true

require "test_helper"

class LiveConversations::SettingsUpdateTest < ActiveSupport::TestCase
  Update = LiveConversations::SettingsUpdate

  setup do
    @human = Update::Actor.human("web: /live/settings")
  end

  test "reads answer today's behaviour before anything is written" do
    setting = LiveSetting.current

    assert_not setting.persisted?
    assert_equal "gpt-6-luna", setting.effective(:text_model)
    assert_equal "gpt-realtime-2.1-mini", setting.effective(:voice_model)
    assert_equal "marin", setting.effective(:voice_name)
    assert_in_delta 1.0, setting.effective(:voice_speed)
    assert_equal "semantic_vad", setting.effective(:voice_turn_detection)
    assert_nil setting.effective(:text_temperature)
    assert_equal "", setting.guidance_text
  end

  test "a write saves, records who made it field by field, and reads back" do
    result = Update.call({ "voice_speed" => "1.3", "voice_model" => "gpt-realtime-2.1", "guidance" => "Be terse." }, actor: @human)

    assert result.changed?
    setting = LiveSetting.current
    assert_in_delta 1.3, setting.effective(:voice_speed)
    assert_equal "gpt-realtime-2.1", setting.effective(:voice_model)
    assert_equal "Be terse.", setting.guidance_text
    assert_equal "human: web: /live/settings", setting.updated_by

    change = LiveSettingChange.sole
    assert_equal "human", change.actor_kind
    assert_equal({ "voice_speed" => [ nil, 1.3 ], "voice_model" => [ nil, "gpt-realtime-2.1" ], "guidance" => [ "", "Be terse." ] }, change.changeset)
    assert_match(/Speaking speed: default \(1\.0\) → 1\.3/, result.summary)
    assert result.mid_call_changed?
  end

  test "an unknown setting or a model off the list is refused, and nothing is saved" do
    error = assert_raises(Update::Invalid) do
      Update.call({ "voice_speed" => "1.2", "voice_model" => "gpt-9-imaginary", "volume" => "11" }, actor: @human)
    end

    assert_match(/gpt-9-imaginary/, error.message)
    assert_match(/Unknown setting "volume"/, error.message)
    assert_not LiveSetting.exists?
    assert_equal 0, LiveSettingChange.count
  end

  test "numbers out of range are clamped and the answer says so; nonsense is refused" do
    result = Update.call({ "voice_speed" => 4, "voice_vad_threshold" => 1.0 }, actor: @human)

    assert_in_delta 1.5, LiveSetting.current.voice_speed
    assert_in_delta 0.95, LiveSetting.current.voice_vad_threshold
    assert_match(/outside 0\.25–1\.5, so it was set to 1\.5/, result.summary)

    assert_raises(Update::Invalid) { Update.call({ "voice_speed" => "fast" }, actor: @human) }
    assert_raises(Update::Invalid) { Update.call({ "voice_speed" => "1e400" }, actor: @human) }
  end

  test "append_guidance adds a line; blank and default put a setting back; reset leaves the guidance" do
    Update.call({ "guidance" => "Be terse.", "voice_speed" => 1.2, "text_temperature" => 0.4 }, actor: @human)
    result = Update.call({ "append_guidance" => "Never read URLs aloud." }, actor: Update::Actor.agent("live conversation #1"))

    assert_equal "Be terse.\nNever read URLs aloud.", LiveSetting.current.guidance_text
    assert_match(/Guidance appended: “Never read URLs aloud\.”/, result.summary)

    Update.call({ "voice_speed" => "default" }, actor: @human)
    assert_nil LiveSetting.current.voice_speed

    Update.call({}, actor: @human, reset: true)
    setting = LiveSetting.current
    assert_nil setting.text_temperature
    assert_equal "Be terse.\nNever read URLs aloud.", setting.guidance_text
    assert_equal 4, LiveSettingChange.count
  end

  test "a write that changes nothing records nothing" do
    Update.call({ "voice_speed" => 1.2 }, actor: @human)
    result = Update.call({ "voice_speed" => "1.2" }, actor: @human)

    assert_not result.changed?
    assert_equal 1, LiveSettingChange.count
  end

  test "the database holds one row, however a race goes" do
    LiveSetting.create!
    assert_raises(ActiveRecord::RecordNotUnique) { LiveSetting.new.save!(validate: false) }
    assert_equal LiveSetting.first, LiveSetting.editable
  end

  test "the guidance has a length cap" do
    assert_raises(Update::Invalid) do
      Update.call({ "guidance" => "x" * (LiveSetting::GUIDANCE_MAX_LENGTH + 1) }, actor: @human)
    end
  end
end
