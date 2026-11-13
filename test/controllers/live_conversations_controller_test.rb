# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "support/fake_parameter_store"

class LiveConversationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    stub_live_root
    stub_live_key
  end

  test "the main screen offers one Live Mode, with no separate Live Voice" do
    get root_path

    assert_response :success
    assert_select "a[data-live-entry=live][href=?]", current_live_path, text: /Live Mode/
    assert_select "a[data-live-entry=mobile][href=?]", current_live_path
    assert_select "a[data-live-entry=voice]", count: 0
    assert_no_match(/Live Voice/, response.body)
  end

  test "the call dock is in the layout, outside the page body Turbo replaces" do
    get live_path

    assert_select "#live-voice-dock[data-turbo-permanent][data-controller=live-voice]"
  end

  test "overview shows Live Mode and the key's state without its value" do
    status = SecretPresence::Status.new(variable: "LIVE_OPENAI_API_KEY", present: true, provider_badge: "ENV",
      path: "/zimmer/test/secrets/static/LIVE_OPENAI_API_KEY")

    SecretPresence.stub(:for, status) do
      get live_path
    end

    assert_response :success
    assert_select "[data-live-mode-card]", count: 1
    assert_select "[data-live-mode-card] a[href=?]", current_live_path
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

  test "the entry point offers to start when it can, and resumes the current conversation, typed or spoken" do
    get current_live_path
    assert_select "[data-live-start] form[action=?]", live_conversations_path

    conversation = create_live_conversation(mode: "voice")
    get current_live_path
    assert_redirected_to live_conversation_path(conversation)
  end

  test "the old per-mode URLs land on the one entry point" do
    get "/live/voice"
    assert_redirected_to "/live/current"
    get "/live/text"
    assert_redirected_to "/live/current"
  end

    test "an unknown mode to start in goes back to the overview" do
    post live_conversations_path, params: { mode: "video" }

    assert_redirected_to live_path
  end

  test "a missing root says so instead of crashing" do
    stub_live_root(root: nil)

    get current_live_path

    assert_response :success
    assert_select "[data-live-unavailable]", text: /no `live-mode` agent root yet/
  end

  test "starting a conversation prepares it and opens its page" do
    assert_enqueued_with(job: LiveConversationPrepareJob) do
      post live_conversations_path
    end
    conversation = LiveConversation.last
    assert conversation.text?
    assert_redirected_to live_conversation_path(conversation)

    get live_conversation_path(conversation)
    assert_select "[data-live-conversation-status=preparing]"
    assert_select "textarea[name=content]"
    assert_select "button[data-live-enable-voice][data-action='live-thread#enableVoice']", text: /Enable voice/
  end

  test "starting when unavailable comes back with the reason" do
    stub_live_root(root: nil)

    post live_conversations_path

    assert_redirected_to current_live_path(start: 1)
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

  test "with voice on, the page renders Talk and Type instead, wired to the relay and mode endpoints" do
    conversation = create_live_conversation(mode: "voice")
    conversation.turns.create!(role: "tool", tool_name: "zimmer", call_id: "c1", tool_arguments: { "tool" => "quick_router" }, tool_output: "Started https://zimmer.example.com/sessions/42")

    get live_conversation_path(conversation)

    assert_select "[data-controller=live-thread][data-client-secret-url=?][data-tool-calls-url=?][data-mode-url=?]",
      client_secret_live_conversation_path(conversation), tool_calls_live_conversation_path(conversation), mode_live_conversation_path(conversation)
    assert_select "button[data-live-thread-target=talk]"
    assert_select "button[data-live-disable-voice]", text: /Type instead/
    assert_select "textarea[name=content]", count: 0
    assert_select "[data-live-mode=voice]", text: /Voice on/
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

  test "the dock's hang-up is answered with hang_up" do
    conversation = create_live_conversation(mode: "voice")

    post tool_calls_live_conversation_path(conversation), params: { name: "hang_up", arguments: "{}", call_id: "call_h", hangs_up: 1 }, as: :json

    assert_response :success
    assert_equal true, response.parsed_body["hang_up"]
    assert_equal "hang_up", conversation.turns.last.tool_name
  end

  test "voice relay refuses a secret while voice is off, and anything on an ended conversation" do
    text = create_live_conversation(mode: "text")
    post client_secret_live_conversation_path(text), as: :json
    assert_response :conflict
    assert_match(/Voice is off/, response.parsed_body["error"])
    text.end!

    voice = create_live_conversation(mode: "voice", status: LiveConversation::ENDED)
    post client_secret_live_conversation_path(voice), as: :json
    assert_response :conflict
    assert_match(/has ended/, response.parsed_body["error"])
  end

  test "Enable voice and Type instead switch the same conversation" do
    conversation = create_live_conversation(mode: "text")

    post mode_live_conversation_path(conversation), params: { mode: "voice" }, as: :json
    assert_response :success
    assert_equal "voice", response.parsed_body["mode"]
    assert_equal true, response.parsed_body["voice"]
    assert conversation.reload.voice?

    post mode_live_conversation_path(conversation), params: { mode: "text" }
    assert_redirected_to live_conversation_path(conversation)
    assert conversation.reload.text?

    post mode_live_conversation_path(conversation), params: { mode: "video" }, as: :json
    assert_response :unprocessable_entity
  end

  test "ending a conversation" do
    conversation = create_live_conversation(mode: "text")

    post finish_live_conversation_path(conversation)

    assert conversation.reload.ended?
    assert_nil LiveConversation.current
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

  test "an ended conversation offers to go back, and going back makes it current" do
    old = create_live_conversation(status: LiveConversation::ENDED, ended_at: 1.hour.ago)
    old.turns.create!(role: "user", source: "typed", content: "Is main green right now")
    current = create_live_conversation

    get live_conversation_path(old)
    assert_select "form[action=?]", reopen_live_conversation_path(old)
    assert_select "input[name=from_id][value=?]", current.id.to_s
    assert_select "[data-live-moved] a[href=?]", live_conversation_path(current)

    post reopen_live_conversation_path(old), params: { from_id: current.id }

    assert_redirected_to live_conversation_path(old)
    assert old.reload.active?
    assert current.reload.ended?
  end

  test "a stale Go back is refused with the reason" do
    old = create_live_conversation(status: LiveConversation::ENDED, ended_at: 1.hour.ago)
    current = create_live_conversation

    post reopen_live_conversation_path(old), params: { from_id: current.id + 1 }

    assert_redirected_to live_conversation_path(old)
    assert_match(/changed/, flash[:alert])
    assert current.reload.active?
  end

  test "a failed conversation offers no way back, and the open one needs none" do
    failed = create_live_conversation(status: LiveConversation::FAILED)
    get live_conversation_path(failed)
    assert_select "form[action=?]", reopen_live_conversation_path(failed), count: 0
  end

  test "the dock can ask which conversation is current" do
    current = create_live_conversation

    get "/live/current.json"

    assert_response :success
    assert_equal current.id, response.parsed_body["current_id"]
    assert_equal false, response.parsed_body["voice"]
  end

  test "the conversation page shows its scratchpad, read-only, with a way to edit it" do
    conversation = create_live_conversation
    conversation.scratchpad_entries.create!(body: "Session 1234 can't merge yet", written_by: "assistant")

    get live_conversation_path(conversation)

    assert_response :success
    assert_select "##{conversation.scratchpad_dom_id}[data-live-scratchpad]" do
      assert_select "[data-live-scratchpad-entry]", text: /Session 1234 can't merge yet.*Live Mode/m
      assert_select "[data-live-scratchpad-count]", text: "1 of 30 notes"
      assert_select "form", count: 0
      assert_select "a[href=?]", live_conversation_scratchpad_entries_path(conversation), text: "Edit notes"
    end
  end

  test "the scratchpad page adds, edits, removes and clears notes, and tells an open call" do
    conversation = create_live_conversation

    get live_conversation_scratchpad_entries_path(conversation)
    assert_response :success
    assert_select "[data-controller=live-settings-saved]", count: 0

    post live_conversation_scratchpad_entries_path(conversation), params: { body: "Don't raise the docs PR" }
    assert_redirected_to live_conversation_scratchpad_entries_path(conversation, saved: 1)
    note = conversation.scratchpad_entries.sole
    assert_equal "person", note.written_by
    follow_redirect!
    assert_select "[data-controller=live-settings-saved]"
    assert_select "textarea#scratchpad_entry_#{note.id}", text: "Don't raise the docs PR"

    patch live_conversation_scratchpad_entry_path(conversation, note), params: { body: "Docs PR merged" }
    assert_equal "Docs PR merged", note.reload.body

    post live_conversation_scratchpad_entries_path(conversation), params: { body: "x" * 301 }
    follow_redirect!
    assert_match(/at most 300 characters/, response.body)
    assert_equal 1, conversation.scratchpad_entries.count

    delete live_conversation_scratchpad_entry_path(conversation, note)
    assert_empty conversation.scratchpad_entries.reload

    conversation.scratchpad_entries.create!(body: "a", written_by: "assistant")
    delete clear_live_conversation_scratchpad_entries_path(conversation)
    assert_empty conversation.scratchpad_entries.reload
  end

  test "a note id from another conversation is refused on this one's scratchpad page" do
    conversation = create_live_conversation
    other = create_live_conversation(status: LiveConversation::ENDED)
    foreign = other.scratchpad_entries.create!(body: "theirs", written_by: "assistant")

    delete live_conversation_scratchpad_entry_path(conversation, foreign)
    follow_redirect!

    assert_match(/no note #{foreign.id}/, response.body)
    assert LiveScratchpadEntry.exists?(foreign.id)
  end
end
