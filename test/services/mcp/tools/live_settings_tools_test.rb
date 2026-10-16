# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::LiveSettingsToolsTest < ActiveSupport::TestCase
  setup do
    context = Mcp::Context.new(tool_groups: "live_conversations", base_url: "https://zimmer.example.com")
    @get = Mcp::Tools::GetLiveSettings.new(context: context)
    @action = Mcp::Tools::ActionLiveSettings.new(context: context)
  end

  test "both tools are on the live_conversations surface, and the read survives _readonly" do
    names = Mcp::Context.new(tool_groups: "live_conversations").tools.map(&:tool_name)
    assert_includes names, "get_live_settings"
    assert_includes names, "action_live_settings"

    readonly = Mcp::Context.new(tool_groups: "live_conversations_readonly").tools.map(&:tool_name)
    assert_includes readonly, "get_live_settings"
    assert_not_includes readonly, "action_live_settings"
  end

  test "the read lists every setting with its default and choices, and the guidance" do
    result = @get.call({})

    LiveSetting::KEYS.each { |key| assert_includes result, "- #{key} = " }
    assert_includes result, "voice_speed = 1.0 (default)"
    assert_includes result, "choices: gpt-realtime-2.1-mini, gpt-realtime-2.1, gpt-realtime-2"
    assert_includes result, "Live mode guidance:\n(empty)"
    assert_includes result, "https://zimmer.example.com/live/settings"
  end

  test "update changes settings and guidance as an agent's change; a bad value changes nothing" do
    result = @action.call({ "action" => "update", "settings" => { "voice_speed" => 1.2 }, "append_guidance" => "Be brief." })

    assert_match(/Speaking speed: default \(1\.0\) → 1\.2/, result)
    assert_equal "Be brief.", LiveSetting.current.guidance_text
    change = LiveSettingChange.sole
    assert_equal "agent", change.actor_kind
    assert_match(/action_live_settings/, change.actor)

    error = assert_raises(Mcp::ToolError) { @action.call({ "action" => "update", "settings" => { "text_model" => "gpt-2" } }) }
    assert_match(/Nothing changed/, error.message)
    assert_equal 1, LiveSettingChange.count
  end

  test "reset keeps the guidance; restore_guidance undoes an edit" do
    @action.call({ "action" => "update", "settings" => { "voice_name" => "cedar" }, "guidance" => "First." })
    @action.call({ "action" => "update", "guidance" => "Bad rewrite." })
    bad = LiveSettingChange.recent_first.first

    @action.call({ "action" => "reset" })
    assert_nil LiveSetting.current.voice_name
    assert_equal "Bad rewrite.", LiveSetting.current.guidance_text

    @action.call({ "action" => "restore_guidance", "change_id" => bad.id })
    assert_equal "First.", LiveSetting.current.guidance_text
  end
end
