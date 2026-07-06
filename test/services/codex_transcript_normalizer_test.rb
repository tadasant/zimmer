# frozen_string_literal: true

require "test_helper"

class CodexTranscriptNormalizerTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @normalizer = CodexTranscriptNormalizer.new
    @source = CodexTranscriptSource.new(file_system: MockFileSystemAdapter.new)
  end

  Types = OpenTranscript::Types

  def wrap(type, payload, timestamp: "2026-05-29T21:39:11.000Z")
    { "timestamp" => timestamp, "type" => type, "payload" => payload }
  end

  # === normalize: user/assistant messages ===

  test "normalize builds an AssistantMessage from an output_text block" do
    raw = wrap("response_item", {
      "type" => "message", "role" => "assistant",
      "content" => [ { "type" => "output_text", "text" => "Hello there." } ]
    })

    events = @normalizer.normalize(raw, session: @session)

    assert_equal 1, events.length
    event = events.first
    assert_equal Types::ASSISTANT_MESSAGE, event[:type]
    assert_equal [ { "type" => "text", "text" => "Hello there." } ], event[:content]
    assert_equal Time.parse("2026-05-29T21:39:11.000Z"), event[:sort_time]
    assert_equal "2026-05-29T21:39:11.000Z", event[:ts]
    assert_nil event[:transcript_index]
  end

  test "normalize folds user input_text into a UserMessage text part" do
    raw = wrap("response_item", {
      "type" => "message", "role" => "user",
      "content" => [ { "type" => "input_text", "text" => "List the files." } ]
    })

    event = @normalizer.normalize(raw, session: @session).first

    assert_equal Types::USER_MESSAGE, event[:type]
    assert_equal [ { "type" => "text", "text" => "List the files." } ], event[:content]
  end

  test "normalize maps input_image blocks to image ContentParts" do
    raw = wrap("response_item", {
      "type" => "message", "role" => "user",
      "content" => [ { "type" => "input_image", "image_url" => "data:image/png;base64,AAAA" } ]
    })

    event = @normalizer.normalize(raw, session: @session).first

    assert_equal [ { "type" => "image", "data" => "data:image/png;base64,AAAA", "mime_type" => nil } ], event[:content]
  end

  test "normalize returns an empty array for a message with no renderable content" do
    raw = wrap("response_item", { "type" => "message", "role" => "assistant", "content" => [] })

    assert_equal [], @normalizer.normalize(raw, session: @session)
  end

  test "normalize includes transcript_index when provided" do
    raw = wrap("response_item", {
      "type" => "message", "role" => "assistant",
      "content" => [ { "type" => "output_text", "text" => "hi" } ]
    })

    event = @normalizer.normalize(raw, session: @session, transcript_index: 4).first

    assert_equal 4, event[:transcript_index]
    assert_equal "codex-4", event[:id]
  end

  # === normalize: tool calls ===

  test "normalize maps a function_call to a ToolCall with parsed arguments" do
    raw = wrap("response_item", {
      "type" => "function_call", "name" => "shell",
      "arguments" => "{\"command\":[\"ls\",\"-la\"]}", "call_id" => "call_abc123"
    })

    event = @normalizer.normalize(raw, session: @session).first

    assert_equal Types::TOOL_CALL, event[:type]
    assert_equal "shell", event[:tool_name]
    assert_equal "call_abc123", event[:tool_call_id]
    assert_equal({ "command" => [ "ls", "-la" ] }, event[:arguments])
  end

  test "normalize wraps non-JSON-object function_call arguments in a Hash" do
    raw = wrap("response_item", {
      "type" => "function_call", "name" => "tool", "arguments" => "not json", "call_id" => "c1"
    })

    event = @normalizer.normalize(raw, session: @session).first

    assert_equal({ "arguments" => "not json" }, event[:arguments])
  end

  test "normalize maps a local_shell_call to a shell ToolCall" do
    raw = wrap("response_item", {
      "type" => "local_shell_call", "call_id" => "c9",
      "action" => { "type" => "exec", "command" => [ "cat", "README.md" ] }
    })

    event = @normalizer.normalize(raw, session: @session).first

    assert_equal Types::TOOL_CALL, event[:type]
    assert_equal "shell", event[:tool_name]
    assert_equal "c9", event[:tool_call_id]
    assert_equal({ "type" => "exec", "command" => [ "cat", "README.md" ] }, event[:arguments])
  end

  test "normalize maps a custom_tool_call to a ToolCall" do
    raw = wrap("response_item", {
      "type" => "custom_tool_call", "name" => "my_tool", "input" => "raw payload", "call_id" => "c5"
    })

    event = @normalizer.normalize(raw, session: @session).first

    assert_equal "my_tool", event[:tool_name]
    assert_equal({ "input" => "raw payload" }, event[:arguments])
  end

  # === normalize: tool outputs ===

  test "normalize maps a function_call_output string to a ToolResult" do
    raw = wrap("response_item", {
      "type" => "function_call_output", "call_id" => "call_abc123", "output" => "total 8\nREADME.md"
    })

    event = @normalizer.normalize(raw, session: @session).first

    assert_equal Types::TOOL_RESULT, event[:type]
    assert_equal "call_abc123", event[:tool_call_id]
    assert_equal [ { "type" => "text", "text" => "total 8\nREADME.md" } ], event[:output]
    refute event[:is_error]
  end

  test "normalize maps an array tool output to text ContentParts" do
    raw = wrap("response_item", {
      "type" => "function_call_output", "call_id" => "c1",
      "output" => [ { "type" => "input_text", "text" => "line one" }, { "type" => "input_text", "text" => "line two" } ]
    })

    event = @normalizer.normalize(raw, session: @session).first

    assert_equal [ { "type" => "text", "text" => "line one" }, { "type" => "text", "text" => "line two" } ],
      event[:output]
  end

  test "normalize maps a custom_tool_call_output to a ToolResult" do
    raw = wrap("response_item", {
      "type" => "custom_tool_call_output", "call_id" => "c5", "output" => "done"
    })

    event = @normalizer.normalize(raw, session: @session).first

    assert_equal Types::TOOL_RESULT, event[:type]
    assert_equal [ { "type" => "text", "text" => "done" } ], event[:output]
  end

  # === normalize: reasoning ===

  test "normalize maps reasoning summary to a Thinking event" do
    raw = wrap("response_item", {
      "type" => "reasoning",
      "summary" => [ { "type" => "summary_text", "text" => "First I will inspect the tree." } ]
    })

    event = @normalizer.normalize(raw, session: @session).first

    assert_equal Types::THINKING, event[:type]
    assert_equal "First I will inspect the tree.", event[:text]
  end

  test "normalize falls back to reasoning content when the summary is empty" do
    raw = wrap("response_item", {
      "type" => "reasoning", "summary" => [],
      "content" => [ { "type" => "reasoning_text", "text" => "deep thoughts" } ]
    })

    event = @normalizer.normalize(raw, session: @session).first

    assert_equal "deep thoughts", event[:text]
  end

  test "normalize returns an empty array for reasoning with no text" do
    raw = wrap("response_item", { "type" => "reasoning", "summary" => [] })

    assert_equal [], @normalizer.normalize(raw, session: @session)
  end

  # === normalize: skipped event types ===

  test "normalize returns an empty array for event_msg lines (UI duplicates)" do
    raw = wrap("event_msg", { "type" => "agent_message", "message" => "hi" })

    assert_equal [], @normalizer.normalize(raw, session: @session)
  end

  test "normalize returns an empty array for session_meta and turn_context lines" do
    assert_equal [], @normalizer.normalize(wrap("session_meta", { "id" => "x" }), session: @session)
    assert_equal [], @normalizer.normalize(wrap("turn_context", { "model" => "gpt-5-codex" }), session: @session)
  end

  test "normalize returns an empty array for an unhandled response_item type" do
    raw = wrap("response_item", { "type" => "web_search_call", "query" => "ruby" })

    assert_equal [], @normalizer.normalize(raw, session: @session)
  end

  # === normalize: compacted ===

  test "normalize maps a compacted line to a Compaction event" do
    raw = wrap("compacted", { "message" => "Summary: the session was compacted." })

    event = @normalizer.normalize(raw, session: @session).first

    assert_equal Types::COMPACTION, event[:type]
    assert_equal "Summary: the session was compacted.", event[:summary]
  end

  # === normalize: timestamp fallback ===

  test "normalize falls back to session.created_at when the timestamp is missing, never null ts" do
    raw = { "type" => "response_item", "payload" => {
      "type" => "message", "role" => "assistant", "content" => [ { "type" => "output_text", "text" => "hi" } ]
    } }

    event = @normalizer.normalize(raw, session: @session).first

    assert_equal @session.created_at, event[:sort_time]
    assert_equal @session.created_at.iso8601, event[:ts]
    refute_nil event[:ts]
  end

  # === extract_session_id ===

  test "extract_session_id reads the id from a session_meta payload" do
    raw = wrap("session_meta", { "id" => "0199b3d2-codex", "cwd" => "/x" })

    assert_equal "0199b3d2-codex", @normalizer.extract_session_id(raw)
  end

  test "extract_session_id returns nil for non-session_meta events" do
    assert_nil @normalizer.extract_session_id(wrap("response_item", { "type" => "message" }))
  end

  # === mints_own_session_id? ===

  test "mints_own_session_id? is true (Codex generates its own rollout UUID)" do
    assert_equal true, @normalizer.mints_own_session_id?
  end

  # === extract_subagent_links / extract_subagent_spawns ===

  test "extract_subagent_links always returns an empty array" do
    assert_equal [], @normalizer.extract_subagent_links(wrap("response_item", { "type" => "function_call" }))
  end

  test "extract_subagent_spawns always returns an empty array" do
    assert_equal [], @normalizer.extract_subagent_spawns(wrap("response_item", { "type" => "function_call" }))
  end

  # === end-to-end against the golden fixture ===

  test "normalizing the golden rollout yields the expected OpenTranscripts timeline" do
    plaintext = File.read(file_fixture("codex_rollout.jsonl").to_s)
    events = @source.parse_events(plaintext)

    items = events.each_with_index.flat_map do |event, i|
      @normalizer.normalize(event, session: @session, transcript_index: i)
    end

    # session_meta, turn_context, and the three event_msg lines are all skipped —
    # only response_item lines + the compacted line surface. The order:
    # user message, reasoning(Thinking), function_call(ToolCall),
    # function_call_output(ToolResult), assistant message, local_shell_call(ToolCall),
    # compacted(Compaction).
    assert_equal 7, items.length
    assert_equal [
      Types::USER_MESSAGE,
      Types::THINKING,
      Types::TOOL_CALL,
      Types::TOOL_RESULT,
      Types::ASSISTANT_MESSAGE,
      Types::TOOL_CALL,
      Types::COMPACTION
    ], items.map { |it| it[:type] }

    assert_equal "shell", items[5][:tool_name]
    assert_equal "Summary: user asked for a directory listing; assistant ran ls and reported README.md.",
      items[6][:summary]

    # No subagent links/spawns anywhere in a Codex transcript.
    assert events.all? { |e| @normalizer.extract_subagent_links(e).empty? }
    assert events.all? { |e| @normalizer.extract_subagent_spawns(e).empty? }

    # Session id is recoverable from the session_meta line.
    session_meta = events.find { |e| e["type"] == "session_meta" }
    assert_equal "0199b3d2-codex-4d2e-8f1a-rollout000001", @normalizer.extract_session_id(session_meta)
  end
end
