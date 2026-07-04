# frozen_string_literal: true

require "test_helper"

class ClaudeTranscriptNormalizerTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @normalizer = ClaudeTranscriptNormalizer.new
  end

  Types = OpenTranscript::Types

  def types_of(events)
    events.map { |e| e[:type] }
  end

  # === normalize: assistant lines ===

  test "normalize fans an assistant text+tool_use line into AssistantMessage + ToolCall" do
    raw = {
      "type" => "assistant",
      "uuid" => "u1",
      "timestamp" => "2025-11-20T10:00:00Z",
      "message" => {
        "role" => "assistant",
        "model" => "claude-opus-4",
        "stop_reason" => "tool_use",
        "content" => [
          { "type" => "text", "text" => "hi" },
          { "type" => "tool_use", "name" => "Bash", "id" => "t1", "input" => { "command" => "ls" } }
        ]
      }
    }

    events = @normalizer.normalize(raw, session: @session)

    assert_equal [ Types::ASSISTANT_MESSAGE, Types::TOOL_CALL ], types_of(events)

    am = events[0]
    assert_equal "u1", am[:id]
    assert_equal [ { "type" => "text", "text" => "hi" } ], am[:content]
    assert_equal "claude-opus-4", am[:model]
    assert_equal "tool_use", am[:stop_reason]
    assert_equal Time.parse("2025-11-20T10:00:00Z"), am[:sort_time]
    assert_equal "2025-11-20T10:00:00Z", am[:ts]
    assert_equal 0, am[:event_order]

    tc = events[1]
    assert_equal "u1:tool:0", tc[:id]
    assert_equal "u1", tc[:parent_id]
    assert_equal "t1", tc[:tool_call_id]
    assert_equal "Bash", tc[:tool_name]
    assert_equal({ "command" => "ls" }, tc[:arguments])
  end

  test "normalize emits a Thinking event per thinking block" do
    raw = {
      "type" => "assistant",
      "uuid" => "u2",
      "message" => {
        "role" => "assistant",
        "content" => [
          { "type" => "thinking", "thinking" => "let me reason", "signature" => "sig" },
          { "type" => "text", "text" => "answer" }
        ]
      }
    }

    events = @normalizer.normalize(raw, session: @session)

    assert_equal [ Types::ASSISTANT_MESSAGE, Types::THINKING ], types_of(events)
    thinking = events.find { |e| e[:type] == Types::THINKING }
    assert_equal "let me reason", thinking[:text]
    assert_equal "sig", thinking[:signature]
    refute thinking[:redacted]
    assert_equal "u2", thinking[:parent_id]
  end

  test "normalize flags redacted_thinking blocks" do
    raw = {
      "type" => "assistant",
      "uuid" => "u3",
      "message" => { "role" => "assistant", "content" => [ { "type" => "redacted_thinking" } ] }
    }

    events = @normalizer.normalize(raw, session: @session)
    thinking = events.find { |e| e[:type] == Types::THINKING }

    assert thinking[:redacted]
  end

  test "normalize records usage on the AssistantMessage" do
    raw = {
      "type" => "assistant",
      "uuid" => "u4",
      "message" => {
        "role" => "assistant",
        "content" => [ { "type" => "text", "text" => "hi" } ],
        "usage" => { "input_tokens" => 10, "output_tokens" => 5, "cache_read_input_tokens" => 2, "cache_creation_input_tokens" => 1 }
      }
    }

    am = @normalizer.normalize(raw, session: @session).first

    assert_equal({ input_tokens: 10, output_tokens: 5, cache_read_tokens: 2, cache_write_tokens: 1 }, am[:usage])
  end

  # === normalize: Task/Agent subagent spawns ===

  test "normalize emits ToolCall + SubagentSpawn for a Task tool_use" do
    raw = {
      "type" => "assistant",
      "uuid" => "u5",
      "message" => {
        "role" => "assistant",
        "content" => [
          { "type" => "tool_use", "name" => "Task", "id" => "task1",
            "input" => { "subagent_type" => "Explore", "description" => "look", "prompt" => "go" } }
        ]
      }
    }

    events = @normalizer.normalize(raw, session: @session)

    assert_equal [ Types::ASSISTANT_MESSAGE, Types::TOOL_CALL, Types::SUBAGENT_SPAWN ], types_of(events)
    spawn = events.find { |e| e[:type] == Types::SUBAGENT_SPAWN }
    assert_equal "task1", spawn[:tool_call_id]
    assert_equal "Explore", spawn[:subagent_type]
    assert_equal "look", spawn[:description]
    assert_equal "go", spawn[:prompt]
    assert_nil spawn[:spawned_transcript_id]
  end

  test "normalize treats the Agent tool name as a subagent spawn too" do
    raw = {
      "type" => "assistant",
      "uuid" => "u6",
      "message" => {
        "role" => "assistant",
        "content" => [ { "type" => "tool_use", "name" => "Agent", "id" => "ag1", "input" => {} } ]
      }
    }

    events = @normalizer.normalize(raw, session: @session)

    assert_includes types_of(events), Types::SUBAGENT_SPAWN
  end

  test "normalize populates spawned_transcript_id from the subagents map" do
    raw = {
      "type" => "assistant",
      "uuid" => "u7",
      "message" => {
        "role" => "assistant",
        "content" => [ { "type" => "tool_use", "name" => "Task", "id" => "task9", "input" => {} } ]
      }
    }

    events = @normalizer.normalize(raw, session: @session, subagents_by_tool_use_id: { "task9" => "sub-transcript-1" })
    spawn = events.find { |e| e[:type] == Types::SUBAGENT_SPAWN }

    assert_equal "sub-transcript-1", spawn[:spawned_transcript_id]
  end

  # === normalize: user lines ===

  test "normalize maps a user text line to a single UserMessage" do
    raw = { "type" => "user", "uuid" => "u8", "message" => { "role" => "user", "content" => "hello" } }

    events = @normalizer.normalize(raw, session: @session)

    assert_equal [ Types::USER_MESSAGE ], types_of(events)
    assert_equal [ { "type" => "text", "text" => "hello" } ], events.first[:content]
  end

  test "normalize reads role/content from the top level when the message envelope is absent" do
    # Some user lines carry role/content directly, with no nested "message"
    # envelope. The content must still be captured (not dropped to empty), so the
    # event is a renderable UserMessage rather than a content-less one that the
    # timeline would suppress.
    raw = { "type" => "user", "uuid" => "u8b", "role" => "user", "content" => "Direct message content" }

    events = @normalizer.normalize(raw, session: @session)

    assert_equal [ Types::USER_MESSAGE ], types_of(events)
    assert_equal [ { "type" => "text", "text" => "Direct message content" } ], events.first[:content]
  end

  test "normalize maps each tool_result block to its own ToolResult event" do
    raw = {
      "type" => "user",
      "uuid" => "u9",
      "message" => {
        "role" => "user",
        "content" => [
          { "type" => "tool_result", "tool_use_id" => "t1", "content" => "out one" },
          { "type" => "tool_result", "tool_use_id" => "t2", "content" => "out two", "is_error" => true }
        ]
      }
    }

    events = @normalizer.normalize(raw, session: @session)

    assert_equal [ Types::TOOL_RESULT, Types::TOOL_RESULT ], types_of(events)
    assert_equal "t1", events[0][:tool_call_id]
    assert_equal "u9", events[0][:id]
    assert_equal [ { "type" => "text", "text" => "out one" } ], events[0][:output]
    refute events[0][:is_error]

    assert_equal "t2", events[1][:tool_call_id]
    assert_equal "u9:toolresult:1", events[1][:id]
    assert events[1][:is_error]
  end

  test "normalize includes transcript_index on every fanned-out event" do
    raw = {
      "type" => "assistant",
      "uuid" => "u10",
      "message" => {
        "role" => "assistant",
        "content" => [ { "type" => "text", "text" => "hi" }, { "type" => "tool_use", "name" => "Bash", "id" => "t1", "input" => {} } ]
      }
    }

    events = @normalizer.normalize(raw, session: @session, transcript_index: 7)

    assert events.all? { |e| e[:transcript_index] == 7 }
  end

  # === normalize: system + unknown lines ===

  test "normalize maps a compact_boundary system line to a Compaction event" do
    raw = {
      "type" => "system",
      "subtype" => "compact_boundary",
      "content" => "Conversation compacted",
      "compactMetadata" => { "trigger" => "auto", "preTokens" => 1000, "postTokens" => 200 }
    }

    events = @normalizer.normalize(raw, session: @session)

    assert_equal [ Types::COMPACTION ], types_of(events)
    comp = events.first
    assert_equal "Conversation compacted", comp[:summary]
    assert_equal "auto", comp[:trigger]
    assert_equal 1000, comp[:tokens_before]
    assert_equal 200, comp[:tokens_after]
  end

  test "normalize maps an error-looking system line to an Error event" do
    raw = { "type" => "system", "content" => "API Error: rate limited" }

    events = @normalizer.normalize(raw, session: @session)

    assert_equal [ Types::ERROR ], types_of(events)
    assert_equal "API Error: rate limited", events.first[:message]
    assert events.first[:recoverable]
  end

  test "normalize maps a benign system line to a SystemEvent" do
    raw = { "type" => "system", "content" => "Tip: use /help" }

    events = @normalizer.normalize(raw, session: @session)

    assert_equal [ Types::SYSTEM_EVENT ], types_of(events)
    assert_equal "system", events.first[:subtype]
  end

  test "normalize maps an unknown line type to a SystemEvent tagged with the subtype" do
    raw = { "type" => "queue-operation", "message" => { "content" => "queued" } }

    events = @normalizer.normalize(raw, session: @session)

    assert_equal [ Types::SYSTEM_EVENT ], types_of(events)
    assert_equal "queue-operation", events.first[:subtype]
  end

  test "normalize falls back to session.created_at when the timestamp is missing, never null ts" do
    raw = { "type" => "user", "uuid" => "u11", "message" => { "role" => "user", "content" => "hi" } }

    event = @normalizer.normalize(raw, session: @session).first

    assert_equal @session.created_at, event[:sort_time]
    assert_equal @session.created_at.iso8601, event[:ts]
    refute_nil event[:ts]
  end

  # === extract_session_id ===

  test "extract_session_id reads the sessionId field" do
    assert_equal "uuid-1", @normalizer.extract_session_id({ "sessionId" => "uuid-1" })
    assert_nil @normalizer.extract_session_id({})
  end

  # === mints_own_session_id? ===

  test "mints_own_session_id? is false (Claude honors the AO-supplied id)" do
    assert_equal false, @normalizer.mints_own_session_id?
  end

  # === extract_subagent_spawns ===

  test "extract_subagent_spawns returns Task tool_use descriptors" do
    raw = {
      "message" => {
        "role" => "assistant",
        "content" => [
          { "type" => "tool_use", "id" => "t1", "name" => "Task", "input" => { "subagent_type" => "Explore", "description" => "look" } },
          { "type" => "tool_use", "id" => "t2", "name" => "Bash", "input" => {} }
        ]
      }
    }

    spawns = @normalizer.extract_subagent_spawns(raw)

    assert_equal [ { tool_use_id: "t1", subagent_type: "Explore", description: "look" } ], spawns
  end

  test "extract_subagent_spawns returns empty array when content is not an array" do
    assert_equal [], @normalizer.extract_subagent_spawns({ "message" => { "content" => nil } })
  end

  # === extract_subagent_links ===

  test "extract_subagent_links returns link descriptors for tool_results with an agentId" do
    raw = {
      "message" => {
        "role" => "user",
        "content" => [
          {
            "type" => "tool_result",
            "tool_use_id" => "t1",
            "toolUseResult" => {
              "agentId" => "abc123",
              "status" => "completed",
              "totalDurationMs" => 5000,
              "totalTokens" => 1000,
              "totalToolUseCount" => 5
            }
          }
        ]
      }
    }

    links = @normalizer.extract_subagent_links(raw)

    assert_equal [ {
      tool_use_id: "t1",
      agent_id: "abc123",
      status: "completed",
      duration_ms: 5000,
      total_tokens: 1000,
      tool_use_count: 5
    } ], links
  end

  test "extract_subagent_links skips Array toolUseResult (e.g. TodoWrite)" do
    raw = {
      "message" => {
        "role" => "user",
        "content" => [
          { "type" => "tool_result", "tool_use_id" => "todo", "toolUseResult" => [ { "status" => "pending" } ] }
        ]
      }
    }

    assert_equal [], @normalizer.extract_subagent_links(raw)
  end

  test "extract_subagent_links skips tool_results without an agentId" do
    raw = {
      "message" => {
        "role" => "user",
        "content" => [
          { "type" => "tool_result", "tool_use_id" => "t1", "toolUseResult" => { "status" => "completed" } }
        ]
      }
    }

    assert_equal [], @normalizer.extract_subagent_links(raw)
  end

  test "extract_subagent_links reads toolUseResult from the top-level event" do
    raw = {
      "message" => {
        "role" => "user",
        "content" => [ { "type" => "tool_result", "tool_use_id" => "t1" } ]
      },
      "toolUseResult" => { "agentId" => "abc" }
    }

    links = @normalizer.extract_subagent_links(raw)

    assert_equal 1, links.length
    assert_equal "abc", links.first[:agent_id]
  end
end
