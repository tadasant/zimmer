# frozen_string_literal: true

require "test_helper"

class LiveConversations::GptLiveSessionTest < ActiveSupport::TestCase
  class FakeLiveOpenai
    attr_reader :requests

    def initialize(failures: [])
      @failures = failures
      @requests = []
    end

    def create_live_session(body)
      @requests << body.deep_stringify_keys
      failure = @failures.shift
      raise failure if failure

      { "session" => { "id" => "live_123" }, "transport" => { "type" => "webrtc", "sdp" => "v=0 answer" } }
    end
  end

  test "starts GPT-Live with the browser's offer, client delegation and front-end instructions with no tool mechanics" do
    conversation = create_live_conversation(mode: "voice")
    conversation.turns.create!(role: "user", source: "spoken", content: "Start the docs fix.")
    client = FakeLiveOpenai.new

    started = LiveConversations::GptLiveSession.start(conversation, sdp: "v=0 offer", client: client)

    assert_equal({ session_id: "live_123", sdp: "v=0 answer", model: "gpt-live-1" }, started)
    body = client.requests.sole
    assert_equal({ "type" => "webrtc", "sdp" => "v=0 offer" }, body["transport"])
    session = body["session"]
    assert_equal "gpt-live-1", session["model"]
    assert_equal({ "type" => "client" }, session["delegation"])
    assert_equal "marin", session.dig("audio", "output", "voice")
    assert_includes session["instructions"], "You have no tools"
    assert_includes session["instructions"], "Them: Start the docs fix."
    assert_not_includes session["instructions"], "`list_mcp_servers`"
    assert_equal "gpt-live-1", conversation.reload.model
  end

  test "a voice GPT-Live refuses is dropped rather than failing the call" do
    LiveSetting.editable.update!(voice_name: "verse")
    client = FakeLiveOpenai.new(failures: [ OpenaiClient::Error.new("bad voice", status: 400) ])

    LiveConversations::GptLiveSession.start(create_live_conversation(mode: "voice"), sdp: "v=0", client: client)

    assert_equal "verse", client.requests.first.dig("session", "audio", "output", "voice")
    assert_nil client.requests.second["session"]["audio"]
  end

  test "refuses an empty offer" do
    assert_raises(LiveConversations::GptLiveSession::Invalid) do
      LiveConversations::GptLiveSession.start(create_live_conversation(mode: "voice"), sdp: "", client: FakeLiveOpenai.new)
    end
  end
end
