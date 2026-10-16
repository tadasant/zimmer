# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class LiveSettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    stub_live_roots
    stub_live_key
  end

  test "the page shows every setting on its default, the guidance, and is reachable from Live and Settings" do
    get live_settings_path

    assert_response :success
    LiveSetting::KEYS.each { |key| assert_select "[data-live-setting-field=#{key}]" }
    assert_select "select#live_setting_voice_model option[value=?]", "gpt-realtime-2.1"
    assert_select "input#live_setting_voice_speed[min='0.25'][max='1.5'][placeholder=?]", "Default (1.0)"
    assert_select "textarea#live_setting_guidance"
    assert_select "[data-controller=live-settings-saved]", count: 0

    get live_path
    assert_select "a[data-live-settings-link][href=?]", live_settings_path
    get settings_path
    assert_select "[data-settings-live] a[href=?]", live_settings_path
    get live_conversation_path(create_live_conversation(mode: "voice"))
    assert_select "a[data-live-settings-link][href=?]", live_settings_path
  end

  test "saving writes only what was edited, records it as a person's, and asks an open call to refresh" do
    LiveConversations::SettingsUpdate.call({ "voice_speed" => 1.2 }, actor: LiveConversations::SettingsUpdate::Actor.agent("live conversation #1"))

    # The page was loaded before the agent's change: speed shows blank there.
    patch live_settings_path, params: {
      live_setting: { voice_speed: "", voice_name: "cedar", guidance: "Keep it short.\r\nNo lists." },
      loaded: { voice_speed: "", voice_name: "", guidance: "" }
    }

    assert_redirected_to live_settings_path
    setting = LiveSetting.current
    assert_in_delta 1.2, setting.voice_speed, 0.001, "an untouched field must not undo the agent's change"
    assert_equal "cedar", setting.voice_name
    assert_equal "Keep it short.\nNo lists.", setting.guidance_text
    assert_equal [ "human", "the settings page" ], [ LiveSettingChange.recent_first.first.actor_kind, LiveSettingChange.recent_first.first.actor ]

    follow_redirect!
    assert_select "[data-controller=live-settings-saved]"
    assert_select "[data-live-settings-history] li[data-live-setting-change]", count: 2
  end

  test "a bad value saves nothing and says why" do
    patch live_settings_path, params: { live_setting: { voice_model: "gpt-9" } }

    assert_redirected_to live_settings_path
    assert_match(/gpt-9/, flash[:alert])
    assert_not LiveSetting.exists?
  end

  test "reset keeps the guidance, and a guidance edit can be restored from the history" do
    actor = LiveConversations::SettingsUpdate::Actor.human("test")
    LiveConversations::SettingsUpdate.call({ "voice_speed" => 1.4, "guidance" => "Good." }, actor: actor)
    bad = LiveConversations::SettingsUpdate.call({ "guidance" => "Bad." }, actor: LiveConversations::SettingsUpdate::Actor.agent("live conversation #2")).change

    post reset_live_settings_path
    assert_nil LiveSetting.current.voice_speed
    assert_equal "Bad.", LiveSetting.current.guidance_text

    post restore_live_settings_guidance_path(bad)
    assert_equal "Good.", LiveSetting.current.guidance_text
  end

  test "an agent's settings change shows in the thread as a note, not a folded tool call" do
    conversation = create_live_conversation(mode: "voice")
    LiveConversations::ToolBridge.new(conversation).execute("update_live_settings", { voice_speed: 1.3 }.to_json, call_id: "c")

    get live_conversation_path(conversation)

    assert_select "[data-live-settings-change]", text: /Speaking speed: default \(1\.0\) → 1\.3/
  end

  test "the call dock can fetch a session.update for an open voice call" do
    conversation = create_live_conversation(mode: "voice")

    post session_update_live_conversation_path(conversation), as: :json

    assert_response :success
    assert_equal "realtime", response.parsed_body.dig("session", "type")
  end
end
