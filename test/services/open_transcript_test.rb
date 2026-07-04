# frozen_string_literal: true

require "test_helper"

class OpenTranscriptTest < ActiveSupport::TestCase
  Types = OpenTranscript::Types

  def make_event(id:, ts:, type: Types::ASSISTANT_MESSAGE, transcript_index: 0, event_order: 0, **fields)
    OpenTranscript.event(
      id: id,
      parent_id: nil,
      ts: ts,
      type: type,
      sort_time: Time.parse(ts),
      transcript_index: transcript_index,
      event_order: event_order,
      **fields
    )
  end

  def transcript(events, subagents: [])
    OpenTranscript.build_transcript(events, agent_name: "claude", vendor: "anthropic", subagents: subagents)
  end

  # === SCHEMA_VERSION pinning ===

  test "SCHEMA_VERSION is pinned to 0.1" do
    assert_equal "0.1", OpenTranscript::SCHEMA_VERSION
  end

  test "Types::ALL lists the nine v0.1 event types" do
    assert_equal 9, Types::ALL.length
    assert_equal %w[
      UserMessage AssistantMessage Thinking ToolCall ToolResult
      SubagentSpawn Compaction Error SystemEvent
    ], Types::ALL
  end

  # === ContentPart / Usage builders ===

  test "text_part builds a text ContentPart with string keys" do
    assert_equal({ "type" => "text", "text" => "hi" }, OpenTranscript.text_part("hi"))
  end

  test "image_part builds an image ContentPart" do
    assert_equal(
      { "type" => "image", "data" => "AAAA", "mime_type" => "image/png" },
      OpenTranscript.image_part(data: "AAAA", mime_type: "image/png")
    )
  end

  test "content_parts_from_blocks maps text and image blocks and drops unknowns" do
    blocks = [
      { "type" => "text", "text" => "hello" },
      { "type" => "image", "source" => { "data" => "BBBB", "media_type" => "image/jpeg" } },
      { "type" => "tool_use", "name" => "Read" }
    ]
    assert_equal [
      { "type" => "text", "text" => "hello" },
      { "type" => "image", "data" => "BBBB", "mime_type" => "image/jpeg" }
    ], OpenTranscript.content_parts_from_blocks(blocks)
  end

  test "usage_from maps anthropic usage keys and returns nil for non-hash" do
    usage = OpenTranscript.usage_from(
      "input_tokens" => 10, "output_tokens" => 5,
      "cache_read_input_tokens" => 2, "cache_creation_input_tokens" => 3
    )
    assert_equal({ input_tokens: 10, output_tokens: 5, cache_read_tokens: 2, cache_write_tokens: 3 }, usage)
    assert_nil OpenTranscript.usage_from("not a hash")
  end

  # === resolve_ts ===

  test "resolve_ts parses a valid timestamp" do
    str, time = OpenTranscript.resolve_ts("2025-11-20T10:00:00Z", Time.now)
    assert_equal "2025-11-20T10:00:00Z", str
    assert_equal Time.parse("2025-11-20T10:00:00Z"), time
  end

  test "resolve_ts falls back on missing or unparseable input, never null" do
    fallback = Time.parse("2020-01-01T00:00:00Z")
    str, time = OpenTranscript.resolve_ts(nil, fallback)
    assert_equal fallback.iso8601, str
    assert_equal fallback, time

    str2, = OpenTranscript.resolve_ts("garbage", fallback)
    assert_equal fallback.iso8601, str2
  end

  # === filter_category ===

  test "filter_category maps event types to DOM categories" do
    assert_equal "message", OpenTranscript.filter_category(make_event(id: "a", ts: "2025-11-20T10:00:00Z", type: Types::USER_MESSAGE))
    assert_equal "message", OpenTranscript.filter_category(make_event(id: "b", ts: "2025-11-20T10:00:00Z", type: Types::COMPACTION))
    assert_equal "tool-message", OpenTranscript.filter_category(make_event(id: "c", ts: "2025-11-20T10:00:00Z", type: Types::TOOL_CALL))
    assert_equal "tool-message", OpenTranscript.filter_category(make_event(id: "d", ts: "2025-11-20T10:00:00Z", type: Types::THINKING))
    assert_equal "queue-event", OpenTranscript.filter_category(make_event(id: "e", ts: "2025-11-20T10:00:00Z", type: Types::SYSTEM_EVENT, subtype: "queue-operation"))
    assert_equal "regular-log", OpenTranscript.filter_category(make_event(id: "f", ts: "2025-11-20T10:00:00Z", type: Types::SYSTEM_EVENT, subtype: "system"))
  end

  test "filter_category handles non-OT log items" do
    assert_equal "verbose-log", OpenTranscript.filter_category({ type: "log", level: "verbose" })
    assert_equal "regular-log", OpenTranscript.filter_category({ type: "log", level: "info" })
    assert_equal "regular-log", OpenTranscript.filter_category({ type: "mcp_log" })
  end

  # === blank_message? ===

  test "blank_message? is true for a message event with no content parts" do
    assert OpenTranscript.blank_message?(make_event(id: "a", ts: "2025-11-20T10:00:00Z", type: Types::ASSISTANT_MESSAGE, content: []))
    assert OpenTranscript.blank_message?(make_event(id: "b", ts: "2025-11-20T10:00:00Z", type: Types::USER_MESSAGE, content: []))
  end

  test "blank_message? is true when content is nil or not an array" do
    assert OpenTranscript.blank_message?(make_event(id: "a", ts: "2025-11-20T10:00:00Z", type: Types::ASSISTANT_MESSAGE, content: nil))
    assert OpenTranscript.blank_message?(make_event(id: "b", ts: "2025-11-20T10:00:00Z", type: Types::ASSISTANT_MESSAGE, content: "not an array"))
  end

  test "blank_message? is true when all text parts are blank or whitespace" do
    parts = [ OpenTranscript.text_part(""), OpenTranscript.text_part("   ") ]
    assert OpenTranscript.blank_message?(make_event(id: "a", ts: "2025-11-20T10:00:00Z", type: Types::ASSISTANT_MESSAGE, content: parts))
  end

  test "blank_message? is false when a non-blank text part is present" do
    parts = [ OpenTranscript.text_part("hello") ]
    refute OpenTranscript.blank_message?(make_event(id: "a", ts: "2025-11-20T10:00:00Z", type: Types::ASSISTANT_MESSAGE, content: parts))
  end

  test "blank_message? is false when an image part is present even without text" do
    parts = [ OpenTranscript.image_part(data: "AAAA", mime_type: "image/png") ]
    refute OpenTranscript.blank_message?(make_event(id: "a", ts: "2025-11-20T10:00:00Z", type: Types::USER_MESSAGE, content: parts))
  end

  test "blank_message? is false for non-message event types regardless of content" do
    # Tool calls, thinking, results, etc. legitimately render without an assistant body.
    refute OpenTranscript.blank_message?(make_event(id: "a", ts: "2025-11-20T10:00:00Z", type: Types::TOOL_CALL, tool_name: "Read"))
    refute OpenTranscript.blank_message?(make_event(id: "b", ts: "2025-11-20T10:00:00Z", type: Types::THINKING, text: "hmm"))
    refute OpenTranscript.blank_message?(make_event(id: "c", ts: "2025-11-20T10:00:00Z", type: Types::TOOL_RESULT, output: []))
    refute OpenTranscript.blank_message?(make_event(id: "d", ts: "2025-11-20T10:00:00Z", type: Types::SUBAGENT_SPAWN))
  end

  # === sort_events stability ===

  test "sort_events orders by sort_time ascending" do
    events = [
      make_event(id: "later", ts: "2025-11-20T10:05:00Z"),
      make_event(id: "earlier", ts: "2025-11-20T10:00:00Z")
    ]
    sorted = OpenTranscript.sort_events(events)
    assert_equal %w[earlier later], sorted.map { |e| e[:id] }
  end

  test "sort_events keeps fan-out order stable within the same timestamp" do
    ts = "2025-11-20T10:00:00Z"
    events = [
      make_event(id: "am", ts: ts, transcript_index: 7, event_order: 0),
      make_event(id: "tool", ts: ts, transcript_index: 7, event_order: 1),
      make_event(id: "spawn", ts: ts, transcript_index: 7, event_order: 2)
    ]
    # Shuffle deterministically (reverse) to prove sort restores fan-out order.
    sorted = OpenTranscript.sort_events(events.reverse)
    assert_equal %w[am tool spawn], sorted.map { |e| e[:id] }
  end

  test "sort_events orders by transcript_index before event_order" do
    ts = "2025-11-20T10:00:00Z"
    events = [
      make_event(id: "line2-first", ts: ts, transcript_index: 2, event_order: 0),
      make_event(id: "line1-second", ts: ts, transcript_index: 1, event_order: 1),
      make_event(id: "line1-first", ts: ts, transcript_index: 1, event_order: 0)
    ]
    sorted = OpenTranscript.sort_events(events)
    assert_equal %w[line1-first line1-second line2-first], sorted.map { |e| e[:id] }
  end

  # === build_transcript envelope ===

  test "build_transcript assembles the v0.1 envelope" do
    events = [
      make_event(id: "a", ts: "2025-11-20T10:00:00Z", usage: { input_tokens: 10, output_tokens: 4 }),
      make_event(id: "b", ts: "2025-11-20T10:01:00Z", usage: { input_tokens: 5, output_tokens: 6 })
    ]
    t = transcript(events)

    assert_equal "0.1", t[:schema_version]
    assert_equal "claude", t.dig(:agent, :name)
    assert_equal "anthropic", t.dig(:provider, :vendor)
    assert_equal "2025-11-20T10:00:00Z", t[:created_at]
    assert_equal "2025-11-20T10:01:00Z", t[:ended_at]
    assert_equal 15, t.dig(:final_metrics, :total_tokens_in)
    assert_equal 10, t.dig(:final_metrics, :total_tokens_out)
    assert_equal 60.0, t.dig(:final_metrics, :wall_clock_s)
  end

  # === validate! invariants ===

  test "validate! passes for a well-formed transcript" do
    events = [
      make_event(id: "a", ts: "2025-11-20T10:00:00Z"),
      make_event(id: "b", ts: "2025-11-20T10:01:00Z")
    ]
    assert OpenTranscript.validate!(transcript(events))
  end

  test "validate! rejects a null ts" do
    bad = make_event(id: "a", ts: "2025-11-20T10:00:00Z")
    bad[:ts] = nil
    t = { events: [ bad ], subagents: [] }
    assert_raises(ArgumentError) { OpenTranscript.validate!(t) }
  end

  test "validate! rejects events out of ascending ts order" do
    later = make_event(id: "a", ts: "2025-11-20T10:05:00Z")
    earlier = make_event(id: "b", ts: "2025-11-20T10:00:00Z")
    # Bypass build_transcript's sort to construct an unsorted envelope.
    t = { events: [ later, earlier ], subagents: [] }
    assert_raises(ArgumentError) { OpenTranscript.validate!(t) }
  end

  test "validate! rejects empty event ids" do
    bad = make_event(id: "", ts: "2025-11-20T10:00:00Z")
    t = { events: [ bad ], subagents: [] }
    assert_raises(ArgumentError) { OpenTranscript.validate!(t) }
  end

  test "validate! rejects duplicate event ids" do
    t = {
      events: [
        make_event(id: "dup", ts: "2025-11-20T10:00:00Z"),
        make_event(id: "dup", ts: "2025-11-20T10:01:00Z")
      ],
      subagents: []
    }
    assert_raises(ArgumentError) { OpenTranscript.validate!(t) }
  end

  test "validate! enforces the SubagentSpawn to subagents bijection" do
    spawn = make_event(id: "s1", ts: "2025-11-20T10:00:00Z", type: Types::SUBAGENT_SPAWN, spawned_transcript_id: "child-1")

    # Spawn references a subagent that exists -> valid.
    sub = { transcript_id: "child-1", events: [], subagents: [] }
    assert OpenTranscript.validate!({ events: [ spawn ], subagents: [ sub ] })

    # Spawn references a missing subagent -> invalid.
    assert_raises(ArgumentError) { OpenTranscript.validate!({ events: [ spawn ], subagents: [] }) }

    # Subagent with no spawn event -> invalid (orphan).
    orphan = make_event(id: "x", ts: "2025-11-20T10:00:00Z")
    assert_raises(ArgumentError) { OpenTranscript.validate!({ events: [ orphan ], subagents: [ sub ] }) }
  end

  test "validate! recurses into subagent transcripts" do
    spawn = make_event(id: "s1", ts: "2025-11-20T10:00:00Z", type: Types::SUBAGENT_SPAWN, spawned_transcript_id: "child-1")
    bad_child_event = make_event(id: "dup", ts: "2025-11-20T10:00:00Z")
    sub = {
      transcript_id: "child-1",
      events: [ bad_child_event, bad_child_event ], # duplicate ids inside the child
      subagents: []
    }
    assert_raises(ArgumentError) { OpenTranscript.validate!({ events: [ spawn ], subagents: [ sub ] }) }
  end
end
