# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "support/fake_parameter_store"

class LiveConversationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    stub_live_roots
    stub_live_key
  end

  test "the main screen offers both live modes" do
    get root_path

    assert_response :success
    assert_select "a[data-live-entry=voice][href=?]", live_mode_path("voice"), text: /Live Voice/
    assert_select "a[data-live-entry=text][href=?]", live_mode_path("text"), text: /Live Mode/
    assert_select "a[data-live-entry=mobile][href=?]", live_path
  end

  test "the call dock is in the layout, outside the page body Turbo replaces" do
    get live_path

    assert_select "#live-voice-dock[data-turbo-permanent][data-controller=live-voice]"
  end

  test "overview shows each mode and the key's state without its value" do
    status = SecretPresence::Status.new(variable: "LIVE_OPENAI_API_KEY", present: true, provider_badge: "ENV",
      path: "/zimmer/test/secrets/static/LIVE_OPENAI_API_KEY")

    SecretPresence.stub(:for, status) do
      get live_path
    end

    assert_response :success
    assert_select "[data-live-mode-card=text]"
    assert_select "[data-live-mode-card=voice]"
    assert_select "[data-live-key-state=set]"
    assert_no_match(/sk-test-live/, response.body)
  end

  test "the key panel offers no form, and links the configured console with the path to use" do
    with_store_console("https://console.example/ui/secrets", "Zimmer test") { with_store_chain { get live_path } }

    assert_select "#live-openai-key input[type=password]", count: 0
    assert_select "#live-openai-key form", count: 0
    assert_select "#live-openai-key a[data-store-console-link][href=?]", "https://console.example/ui/secrets"
    assert_select "#live-openai-key [data-store-console-note]", text: /Zimmer test/
    assert_select "#live-openai-key [data-store-console-note] code", text: "/zimmer/test/secrets/static/LIVE_OPENAI_API_KEY"
  end

  test "with no console configured, the key panel names the path and links nowhere" do
    with_store_console(nil, nil) { with_store_chain { get live_path } }

    assert_select "#live-openai-key [data-store-console-link]", count: 0
    assert_select "#live-openai-key [data-store-console-note] code", text: "/zimmer/test/secrets/static/LIVE_OPENAI_API_KEY"
  end

  test "with no store configured, the key panel names credentials and the environment and links nowhere" do
    no_store = SecretProviders::Chain.new([ SecretProviders::Env.new({}) ])
    with_store_console("https://console.example/ui/secrets", nil) do
      SecretProviders.stub(:chain, no_store) { get live_path }
    end

    assert_select "#live-openai-key [data-store-console-link]", count: 0
    assert_select "#live-openai-key [data-store-console-note] code", text: "/zimmer/test/secrets/static/LIVE_OPENAI_API_KEY", count: 0
    assert_select "#live-openai-key [data-store-console-verb]", text: /no secret store configured/
  end

  test "a mode's page offers to start when it can, and resumes the current conversation when there is one" do
    get live_mode_path("voice")
    assert_select "[data-live-start=voice] form[action=?]", live_conversations_path

    conversation = create_live_conversation(mode: "voice")
    get live_mode_path("voice")
    assert_redirected_to live_conversation_path(conversation)
  end

  test "an unknown mode goes back to the overview" do
    get live_mode_path("video")

    assert_redirected_to live_path
  end

  test "a mode whose root is missing says so instead of crashing" do
    stub_live_roots(text: nil)

    get live_mode_path("text")

    assert_response :success
    assert_select "[data-live-unavailable]", text: /no `live-mode` agent root yet/
  end

  test "starting a conversation prepares it and opens its page" do
    assert_enqueued_with(job: LiveConversationPrepareJob) do
      post live_conversations_path, params: { mode: "text" }
    end
    conversation = LiveConversation.last
    assert_redirected_to live_conversation_path(conversation)

    get live_conversation_path(conversation)
    assert_select "[data-live-conversation-status=preparing]"
    assert_select "textarea[name=content]"
  end

  test "starting when unavailable comes back with the reason" do
    stub_live_roots(text: nil)

    post live_conversations_path, params: { mode: "text" }

    assert_redirected_to live_mode_path("text", start: 1)
    assert_match(/no `live-mode` agent root/, flash[:alert])
  end

  test "a typed message lands in the thread and starts a reply" do
    conversation = create_live_conversation(mode: "text")

    assert_enqueued_with(job: LiveConversationReplyJob, args: [ conversation.id ]) do
      post messages_live_conversation_path(conversation), params: { content: "start a research session" }
    end
    assert_redirected_to live_conversation_path(conversation)
    assert_equal "start a research session", conversation.turns.sole.content

    get live_conversation_path(conversation)
    assert_select "[data-live-turn-role=user]", text: /start a research session/
  end

  test "the voice page renders Talk wired to the relay endpoints" do
    conversation = create_live_conversation(mode: "voice")
    conversation.turns.create!(role: "tool", tool_name: "zimmer", call_id: "c1", tool_arguments: { "tool" => "quick_router" }, tool_output: "Started https://zimmer.example.com/sessions/42")

    get live_conversation_path(conversation)

    assert_select "button[data-live-thread-target=talk][data-client-secret-url=?][data-tool-calls-url=?]",
      client_secret_live_conversation_path(conversation), tool_calls_live_conversation_path(conversation)
    assert_select "[data-live-turn-role=tool] summary", text: /zimmer → quick_router/
    assert_select "[data-live-turn-role=tool] a[href='https://zimmer.example.com/sessions/42']"
  end

  test "voice relay: client secret, tool call and transcript turn" do
    conversation = create_live_conversation(mode: "voice")
    LiveConversations::RealtimeSession.stubs(:mint).returns({ client_secret: "ek_1", calls_url: "https://api.openai.com/v1/realtime/calls" })

    post client_secret_live_conversation_path(conversation), as: :json
    assert_response :success
    assert_equal "ek_1", response.parsed_body["client_secret"]

    post tool_calls_live_conversation_path(conversation), params: { name: "list_mcp_servers", arguments: "{}", call_id: "call_9" }, as: :json
    assert_response :success
    assert_equal false, response.parsed_body["error"]
    assert_equal false, response.parsed_body["tools_changed"]

    post turns_live_conversation_path(conversation), params: { role: "user", content: "what's running?" }, as: :json
    assert_response :created
    assert_equal %w[tool user], conversation.turns.map(&:role)
    assert_equal "spoken", conversation.turns.last.source
  end

  test "voice relay refuses a text conversation and an ended one" do
    text = create_live_conversation(mode: "text")
    post tool_calls_live_conversation_path(text), params: { name: "x", call_id: "c" }, as: :json
    assert_response :unprocessable_entity

    voice = create_live_conversation(mode: "voice", status: LiveConversation::ENDED)
    post client_secret_live_conversation_path(voice), as: :json
    assert_response :conflict
    assert_match(/has ended/, response.parsed_body["error"])
  end

  test "ending a conversation" do
    conversation = create_live_conversation(mode: "text")

    post finish_live_conversation_path(conversation)

    assert conversation.reload.ended?
    assert_nil LiveConversation.current("text")
  end

  private

  def with_store_chain(&block)
    SecretProviders.stub(:chain, FakeParameterStore.new.chain, &block)
  end

  def with_store_console(url, store_name)
    keys = [ SecretsLocation::ENV_STORE_CONSOLE_URL, SecretsLocation::ENV_STORE_CONSOLE_STORE_NAME ]
    original = keys.to_h { |key| [ key, ENV[key] ] }
    ENV[keys[0]] = url
    ENV[keys[1]] = store_name
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end
end
