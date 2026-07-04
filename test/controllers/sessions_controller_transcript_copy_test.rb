require "test_helper"
require "mocha/minitest"

class SessionsControllerTranscriptCopyTest < ActionDispatch::IntegrationTest
  def setup
    # Stub Turbo Stream broadcasting to avoid missing partial errors in tests
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
  end

  def teardown
    Mocha::Mockery.instance.teardown
  end

  # Test transcript action - basic functionality
  test "should get transcript as text" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test session",
      transcript: '{"type":"user","message":{"role":"user","content":"Hello"}}'
    )

    get transcript_session_url(session, format: :text)
    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_includes response.body, "[User]"
    assert_includes response.body, "Hello"
  end

  test "should handle session with no transcript" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Empty session")

    get transcript_session_url(session, format: :text)
    assert_response :success
    assert_equal "", response.body.strip
  end

  test "should redirect to session show page for html format" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test session")

    get transcript_session_url(session, format: :html)
    assert_redirected_to session
  end

  # Test format_transcript_for_copy with various transcript formats
  test "should format simple user and assistant messages" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      transcript: <<~JSONL
        {"type":"user","message":{"role":"user","content":"Hello Claude"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hello! How can I help?"}]}}
      JSONL
    )

    get transcript_session_url(session, format: :text)
    assert_response :success

    assert_includes response.body, "[User]"
    assert_includes response.body, "Hello Claude"
    assert_includes response.body, "[Assistant]"
    assert_includes response.body, "Hello! How can I help?"
    # Messages should be separated by dividers
    assert_includes response.body, "---"
  end

  test "should format tool use blocks" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      transcript: <<~JSONL
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","id":"123","input":{"file_path":"/test.txt"}}]}}
      JSONL
    )

    get transcript_session_url(session, format: :text)
    assert_response :success

    assert_includes response.body, "[Tool Use: Read]"
    assert_includes response.body, "file_path:"
    assert_includes response.body, "/test.txt"
  end

  test "should format tool result blocks" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      transcript: <<~JSONL
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"123","content":"File contents here"}]}}
      JSONL
    )

    get transcript_session_url(session, format: :text)
    assert_response :success

    assert_includes response.body, "[Tool Result]"
    assert_includes response.body, "File contents here"
  end

  test "should format error tool results" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      transcript: <<~JSONL
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"123","content":"Error: file not found","is_error":true}]}}
      JSONL
    )

    get transcript_session_url(session, format: :text)
    assert_response :success

    assert_includes response.body, "[Tool Result (Error)]"
    assert_includes response.body, "Error: file not found"
  end

  test "should format thinking blocks" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      transcript: <<~JSONL
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me consider this..."},{"type":"text","text":"Here is my answer"}]}}
      JSONL
    )

    get transcript_session_url(session, format: :text)
    assert_response :success

    assert_includes response.body, "[Thinking]"
    assert_includes response.body, "Let me consider this..."
    assert_includes response.body, "Here is my answer"
  end

  test "should skip system events and non-conversation entries" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      transcript: <<~JSONL
        {"type":"system","subtype":"init","content":"Session initialized"}
        {"type":"user","message":{"role":"user","content":"Hello"}}
        {"type":"queue-operation","operation":"start","content":"Starting"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hi!"}]}}
      JSONL
    )

    get transcript_session_url(session, format: :text)
    assert_response :success

    # Should include user and assistant messages
    assert_includes response.body, "[User]"
    assert_includes response.body, "Hello"
    assert_includes response.body, "[Assistant]"
    assert_includes response.body, "Hi!"

    # Should not include system events
    refute_includes response.body, "Session initialized"
    refute_includes response.body, "queue-operation"
  end

  test "should handle complex multi-turn conversation" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      transcript: <<~JSONL
        {"type":"user","message":{"role":"user","content":"Read the file test.txt"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll read that file for you."},{"type":"tool_use","name":"Read","id":"tool1","input":{"file_path":"test.txt"}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool1","content":"Hello World"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The file contains: Hello World"}]}}
      JSONL
    )

    get transcript_session_url(session, format: :text)
    assert_response :success

    # Verify the conversation flow is preserved
    body = response.body
    user_1_pos = body.index("Read the file test.txt")
    assistant_1_pos = body.index("I'll read that file for you")
    tool_result_pos = body.index("Hello World")
    assistant_2_pos = body.index("The file contains:")

    # Verify ordering
    assert user_1_pos < assistant_1_pos, "User message should come before assistant's first response"
    assert assistant_1_pos < tool_result_pos, "Tool result should come after assistant's tool use"
    assert tool_result_pos < assistant_2_pos, "Final assistant message should come last"
  end

  test "should handle flat format messages" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      transcript: <<~JSONL
        {"type":"user","role":"user","text":"Simple message"}
      JSONL
    )

    get transcript_session_url(session, format: :text)
    assert_response :success

    assert_includes response.body, "[User]"
    assert_includes response.body, "Simple message"
  end

  test "should handle structured tool result content" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      transcript: <<~JSONL
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"123","content":[{"type":"text","text":"Line 1"},{"type":"text","text":"Line 2"}]}]}}
      JSONL
    )

    get transcript_session_url(session, format: :text)
    assert_response :success

    assert_includes response.body, "Line 1"
    assert_includes response.body, "Line 2"
  end

  test "should handle multi-line tool input values" do
    code = "function hello() {\n  console.log('Hello');\n}"
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      transcript: <<~JSONL
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","id":"123","input":{"file_path":"test.js","content":"#{code.gsub("\n", "\\n")}"}}]}}
      JSONL
    )

    get transcript_session_url(session, format: :text)
    assert_response :success

    assert_includes response.body, "[Tool Use: Write]"
    assert_includes response.body, "file_path:"
    assert_includes response.body, "content:"
  end

  test "should find session by slug" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", slug: "test-session-slug")

    get transcript_session_url("test-session-slug", format: :text)
    assert_response :success
  end

  test "should return 404 for non-existent session" do
    # Session.find will raise RecordNotFound which Rails converts to 404
    # In test environment, this raises the exception
    get transcript_session_url(999999, format: :text)
    assert_response :not_found
  end

  test "should handle malformed JSON in transcript gracefully" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      transcript: <<~JSONL
        not valid json at all
        {"type":"user","message":{"role":"user","content":"Hello"}}
        another broken line {{{
      JSONL
    )

    get transcript_session_url(session, format: :text)
    assert_response :success
    # Should only include valid lines
    assert_includes response.body, "Hello"
    refute_includes response.body, "not valid json"
    refute_includes response.body, "{{{"
  end

  test "should handle nil content in message" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      transcript: '{"type":"user","message":{"role":"user","content":null}}'
    )

    get transcript_session_url(session, format: :text)
    assert_response :success
    # Should not crash, may return empty or skip the message
  end

  test "should handle empty content blocks" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      transcript: '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":""}]}}'
    )

    get transcript_session_url(session, format: :text)
    assert_response :success
    # Should not crash with empty text blocks
  end
end
