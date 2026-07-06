require "test_helper"

class TranscriptHooks::BaseHookTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @transcript_content = <<~JSONL
      {"type":"user","message":{"content":"Hello, world!"}}
      {"type":"assistant","message":{"content":[{"type":"text","text":"Hi there!"}]}}
    JSONL
    @new_messages = []
  end

  test "raises NotImplementedError when call is not overridden" do
    hook = TranscriptHooks::BaseHook.new(
      session: @session,
      transcript_content: @transcript_content,
      new_messages: @new_messages
    )

    assert_raises(NotImplementedError) { hook.call }
  end

  test "update_custom_metadata merges into session custom_metadata" do
    @session.update!(custom_metadata: { "existing" => "value" })

    hook = TestHook.new(
      session: @session,
      transcript_content: @transcript_content,
      new_messages: @new_messages
    )

    hook.test_update_custom_metadata("new_key" => "new_value")

    @session.reload
    assert_equal "value", @session.custom_metadata["existing"]
    assert_equal "new_value", @session.custom_metadata["new_key"]
  end

  test "get_custom_metadata retrieves value from session" do
    @session.update!(custom_metadata: { "test_key" => "test_value" })

    hook = TestHook.new(
      session: @session,
      transcript_content: @transcript_content,
      new_messages: @new_messages
    )

    assert_equal "test_value", hook.test_get_custom_metadata("test_key")
    assert_nil hook.test_get_custom_metadata("nonexistent")
  end

  test "update_custom_metadata reloads session before merging to preserve concurrent updates" do
    # Set initial metadata
    @session.update!(custom_metadata: { "initial" => "value" })

    # Create hook with the session object (which now has { "initial" => "value" })
    hook = TestHook.new(
      session: @session,
      transcript_content: @transcript_content,
      new_messages: @new_messages
    )

    # Simulate another process updating the session directly in the database
    # This bypasses the hook's session object, making it stale
    Session.find(@session.id).update!(custom_metadata: { "initial" => "value", "concurrent" => "update" })

    # The hook should reload the session before merging, so concurrent changes are preserved
    hook.test_update_custom_metadata("new_key" => "new_value")

    @session.reload
    assert_equal "value", @session.custom_metadata["initial"]
    assert_equal "update", @session.custom_metadata["concurrent"], "Concurrent update should be preserved after reload"
    assert_equal "new_value", @session.custom_metadata["new_key"]
  end

  test "get_custom_metadata reloads session to get fresh data" do
    @session.update!(custom_metadata: { "initial" => "value" })

    hook = TestHook.new(
      session: @session,
      transcript_content: @transcript_content,
      new_messages: @new_messages
    )

    # Simulate another process updating the session directly in the database
    Session.find(@session.id).update!(custom_metadata: { "initial" => "value", "new_key" => "fresh_value" })

    # The hook should reload and return the fresh value
    assert_equal "fresh_value", hook.test_get_custom_metadata("new_key"), "Should see freshly updated value after reload"
  end

  test "parsed_transcript parses JSONL content" do
    hook = TestHook.new(
      session: @session,
      transcript_content: @transcript_content,
      new_messages: @new_messages
    )

    parsed = hook.test_parsed_transcript

    assert_equal 2, parsed.length
    assert_equal "user", parsed[0]["type"]
    assert_equal "assistant", parsed[1]["type"]
  end

  test "all_text_content extracts text from messages" do
    hook = TestHook.new(
      session: @session,
      transcript_content: @transcript_content,
      new_messages: @new_messages
    )

    text = hook.test_all_text_content

    assert_includes text, "Hello, world!"
    assert_includes text, "Hi there!"
  end

  test "all_text_content handles empty transcript" do
    hook = TestHook.new(
      session: @session,
      transcript_content: "",
      new_messages: @new_messages
    )

    assert_equal "", hook.test_all_text_content
  end

  test "tool_result_content extracts content from tool results" do
    transcript = <<~JSONL
      {"type":"user","message":{"content":"Hello"}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"First result","is_error":false}]}}
      {"type":"assistant","message":{"content":"Processing..."}}
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_456","type":"tool_result","content":"Second result","is_error":false}]}}
    JSONL

    hook = TestHook.new(
      session: @session,
      transcript_content: transcript,
      new_messages: @new_messages
    )

    text = hook.test_tool_result_content

    assert_includes text, "First result"
    assert_includes text, "Second result"
    refute_includes text, "Hello"
    refute_includes text, "Processing..."
  end

  test "tool_result_content handles empty transcript" do
    hook = TestHook.new(
      session: @session,
      transcript_content: "",
      new_messages: @new_messages
    )

    assert_equal "", hook.test_tool_result_content
  end

  test "tool_result_content handles transcript with no tool results" do
    hook = TestHook.new(
      session: @session,
      transcript_content: @transcript_content,
      new_messages: @new_messages
    )

    assert_equal "", hook.test_tool_result_content
  end

  # Test helper class that exposes protected methods
  class TestHook < TranscriptHooks::BaseHook
    def call
      # No-op implementation
    end

    def test_update_custom_metadata(updates)
      update_custom_metadata(updates)
    end

    def test_get_custom_metadata(key)
      get_custom_metadata(key)
    end

    def test_parsed_transcript
      parsed_transcript
    end

    def test_all_text_content
      all_text_content
    end

    def test_tool_result_content
      tool_result_content
    end
  end
end
