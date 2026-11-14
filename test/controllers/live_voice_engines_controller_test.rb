# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The experimental voice engines on the web call dock: the engine switch on
# client_secret, the GPT-Live session, Claude's delegations, the usage report,
# and /live/costs.
class LiveVoiceEnginesControllerTest < ActionDispatch::IntegrationTest
  setup do
    stub_live_root
    stub_live_key
    stub_claude_key
    @conversation = create_live_conversation(mode: "voice")
    LiveConversations::RealtimeSession.stubs(:mint).returns({ client_secret: "ek_1", calls_url: "https://api.openai.com/v1/realtime/calls" })
  end

  test "with the default engine, the dock gets its Realtime secret as before, named as the engine" do
    post client_secret_live_conversation_path(@conversation), params: { engines: [ "gpt_live_claude" ] }, as: :json

    assert_response :success
    assert_equal "ek_1", response.parsed_body["client_secret"]
    assert_equal "openai_realtime", response.parsed_body["engine"]
    assert_equal "openai_realtime", @conversation.reload.voice_engine
    assert_equal 0, LiveUsageEvent.count
  end

  test "GPT-Live chosen: no secret, and the call starts, delegates to Claude and reports its cost" do
    use_voice_engine("gpt_live_claude")

    post client_secret_live_conversation_path(@conversation), params: { engines: [ "gpt_live_claude" ] }, as: :json
    assert_response :success
    assert_equal "gpt_live_claude", response.parsed_body["engine"]
    assert_nil response.parsed_body["client_secret"]

    LiveConversations::GptLiveSession.expects(:start).with(@conversation, sdp: "v=0 offer").returns({ session_id: "live_1", sdp: "v=0 answer", model: "gpt-live-1" })
    post gpt_live_session_live_conversation_path(@conversation), params: { sdp: "v=0 offer" }, as: :json
    assert_response :success
    assert_equal "v=0 answer", response.parsed_body["sdp"]

    claude = LiveConversationHelpers::FakeClaude.new(responses: [ LiveConversationHelpers::FakeClaude.text("Two sessions are running.") ])
    LiveConversations::ClaudeClient.stubs(:new).returns(claude)
    post delegations_live_conversation_path(@conversation), params: { delegation_id: "item_d1", pending_user_text: "What's running?" }, as: :json
    assert_response :success
    assert_equal [ "Two sessions are running." ], response.parsed_body["chunks"]
    assert_equal false, response.parsed_body["end_call"]

    post usage_live_conversation_path(@conversation),
         params: { events: [ { engine: "gpt_live_claude", operation: "voice_session", key: "x.1", seconds: 60 } ] }, as: :json
    assert_response :created
    assert_in_delta 0.05, response.parsed_body["cost_usd"], 0.000001
    assert_equal %w[delegation voice_session], LiveUsageEvent.order(:id).pluck(:operation)
  end

  test "an engine the client cannot run falls back, and the fallback is on the ledger" do
    use_voice_engine("gpt_live_claude")

    post client_secret_live_conversation_path(@conversation), as: :json

    assert_response :success
    assert_equal "openai_realtime", response.parsed_body["engine"]
    assert_match(/only the web call dock/, response.parsed_body.dig("voice_engine", "fallback_reason"))
    fallback = LiveUsageEvent.sole
    assert_equal [ "gpt_live_claude", "engine_fallback" ], [ fallback.engine, fallback.operation ]
    assert_match(/only the web call dock/, @conversation.reload.voice_engine_fallback)
  end

  test "a call not running on GPT-Live cannot reach it: no session, no Claude" do
    post gpt_live_session_live_conversation_path(@conversation), params: { sdp: "v=0" }, as: :json
    assert_response :conflict

    post delegations_live_conversation_path(@conversation), params: { delegation_id: "d" }, as: :json
    assert_response :conflict
  end

  test "a usage report the server will not take is refused" do
    post usage_live_conversation_path(@conversation), params: { events: [ { engine: "openai_realtime", operation: "delegation", key: "k" } ] }, as: :json

    assert_response :unprocessable_entity
    assert_equal 0, LiveUsageEvent.count
  end

  test "/live/costs shows spend by engine and conversation, and exports the rows" do
    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "voice_session", vendor: "openai_live", model: "gpt-live-1", seconds: 120,
                           live_conversation: @conversation)

    get live_costs_path
    assert_response :success
    assert_select "[data-live-costs-engine=gpt_live_claude]", text: /\$0\.10/
    assert_select "[data-live-costs-conversations] a[href=?]", live_conversation_path(@conversation)
    assert_select "[data-live-costs-caps]", text: /gpt_live_claude/

    get live_costs_path(format: :csv, days: 1)
    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "gpt-live-1"

    get live_path
    assert_select "a[data-live-costs-link][href=?]", live_costs_path
  end

  test "the settings page has the engine section, and a save switches the engine" do
    get live_settings_path
    assert_select "[data-live-settings-section=engine] [data-live-setting-field=voice_engine]"
    assert_select "[data-live-settings-section=engine] [data-live-setting-field=voice_engine_daily_cap_usd]"

    patch live_settings_path, params: { live_setting: { voice_engine: "gpt_live_claude" } }
    assert_equal "gpt_live_claude", LiveSetting.current.effective(:voice_engine)
  end
end
