# frozen_string_literal: true

require "test_helper"

# The `pi_session.jsonl` fixture is not hand-written: it was captured verbatim
# from a real, pinned Pi 0.84.4 process driven against a simulated localhost LLM
# that issued a `bash` tool call (only the header's `cwd` was rewritten to a
# stable path). So these assertions are about the shape Pi actually emits, not
# about a shape we imagined it emits.
class PiTranscriptNormalizerTest < ActiveSupport::TestCase
  setup do
    @normalizer = PiTranscriptNormalizer.new
    @session = Session.new(agent_runtime: "pi", created_at: Time.utc(2026, 9, 1))
    @source = PiTranscriptSource.new
    @events = @source.parse_events(file_fixture("pi_session.jsonl").read)
  end

  test "the captured fixture is a real Pi session tree" do
    assert_equal(
      %w[session model_change thinking_level_change message message message message],
      @events.map { |e| e["type"] }
    )
  end

  test "normalizes the whole fixture into the expected timeline" do
    normalized = @events.each_with_index.flat_map do |raw, index|
      @normalizer.normalize(raw, session: @session, transcript_index: index)
    end

    assert_equal(
      [
        OpenTranscript::Types::USER_MESSAGE,
        OpenTranscript::Types::ASSISTANT_MESSAGE,
        OpenTranscript::Types::TOOL_CALL,
        OpenTranscript::Types::TOOL_RESULT,
        OpenTranscript::Types::ASSISTANT_MESSAGE
      ],
      normalized.map { |e| e[:type] }
    )
  end

  test "the header and the change entries render nothing" do
    %w[session model_change thinking_level_change].each do |type|
      raw = @events.find { |e| e["type"] == type }
      assert_equal [], @normalizer.normalize(raw, session: @session, transcript_index: 0),
        "#{type} should not produce a timeline event"
    end
  end

  test "a user message becomes a UserMessage with its text" do
    event = normalize_message_at(3).sole

    assert_equal OpenTranscript::Types::USER_MESSAGE, event[:type]
    assert_equal "run echo ZIMMER-PI-TOOL-OK", event[:content].first["text"]
  end

  # The substantive difference from the Codex normalizer: one Pi assistant entry
  # can hold text, thinking and tool calls at once, so it fans out.
  test "an assistant entry carrying a tool call fans out into a message plus a ToolCall" do
    message, tool_call = normalize_message_at(4)

    assert_equal OpenTranscript::Types::ASSISTANT_MESSAGE, message[:type]
    assert_equal "zimmer-sim/sim-model", message[:model]
    assert_equal "toolUse", message[:stop_reason]
    assert_equal 20, message[:usage]["input"]
    # No text block in this entry, so the message body is empty — retained for
    # its model/usage metadata, and OpenTranscript.blank_message? keeps the
    # renderer from drawing a bare row for it.
    assert_equal [], message[:content]

    assert_equal OpenTranscript::Types::TOOL_CALL, tool_call[:type]
    assert_equal "bash", tool_call[:tool_name]
    assert_equal "call_sim_1", tool_call[:tool_call_id]
    assert_equal({ "command" => "echo ZIMMER-PI-TOOL-OK" }, tool_call[:arguments])
    # Ordered after the message it belongs to.
    assert_equal 1, tool_call[:event_order]
  end

  test "a toolResult entry becomes a ToolResult carrying the command output" do
    event = normalize_message_at(5).sole

    assert_equal OpenTranscript::Types::TOOL_RESULT, event[:type]
    assert_equal "call_sim_1", event[:tool_call_id]
    assert_equal "ZIMMER-PI-TOOL-OK\n", event[:output].first["text"]
    assert_not event[:is_error]
  end

  test "a plain assistant reply becomes an AssistantMessage with its text" do
    event = normalize_message_at(6).sole

    assert_equal OpenTranscript::Types::ASSISTANT_MESSAGE, event[:type]
    assert_equal "Ran the command. ZIMMER-PI-DONE", event[:content].first["text"]
    assert_equal "stop", event[:stop_reason]
  end

  test "event ids come from Pi's own entry ids so they survive a re-read" do
    ids = @events.each_with_index.flat_map do |raw, index|
      @normalizer.normalize(raw, session: @session, transcript_index: index)
    end.map { |e| e[:id] }

    assert ids.all? { |id| id.start_with?("pi-") }, ids.inspect
    assert_equal ids.uniq, ids, "event ids must be unique"
  end

  test "extract_session_id reads the header id" do
    header = @events.first

    assert_equal header["id"], @normalizer.extract_session_id(header)
    assert_nil @normalizer.extract_session_id(@events.last)
  end

  # Zimmer mints the id and passes --session-id, so Pi's id IS Zimmer's. Answering
  # true here would make forked sessions collide on the unique session_id index.
  test "mints_own_session_id? is false" do
    assert_not @normalizer.mints_own_session_id?
  end

  test "conversation_record? is a deny-list over bookkeeping entries" do
    assert_not @normalizer.conversation_record?({ "type" => "session" })
    assert_not @normalizer.conversation_record?({ "type" => "model_change" })
    assert_not @normalizer.conversation_record?({ "type" => "thinking_level_change" })
    assert_not @normalizer.conversation_record?({ "type" => "custom" })

    assert @normalizer.conversation_record?({ "type" => "message" })
    assert @normalizer.conversation_record?({ "type" => "custom_message" })
    assert @normalizer.conversation_record?({ "type" => "compaction" })
    # An entry type this normalizer has never met still counts as conversation,
    # so a Pi version that adds one cannot cause a real history to be discarded.
    assert @normalizer.conversation_record?({ "type" => "some_future_entry" })
  end

  test "Pi has no subagents" do
    assert_equal [], @normalizer.extract_subagent_links(@events.last)
    assert_equal [], @normalizer.extract_subagent_spawns(@events.last)
  end

  test "thinking blocks become Thinking events ordered within the entry" do
    raw = {
      "type" => "message", "id" => "deadbeef", "timestamp" => "2026-09-01T10:00:00.000Z",
      "message" => {
        "role" => "assistant",
        "content" => [
          { "type" => "thinking", "thinking" => "weighing the options" },
          { "type" => "text", "text" => "here is the answer" }
        ],
        "provider" => "anthropic", "model" => "claude-opus-4-6", "stopReason" => "stop"
      }
    }

    message, thinking = @normalizer.normalize(raw, session: @session, transcript_index: 0)

    assert_equal OpenTranscript::Types::ASSISTANT_MESSAGE, message[:type]
    assert_equal "here is the answer", message[:content].first["text"]
    assert_equal "anthropic/claude-opus-4-6", message[:model]
    assert_equal OpenTranscript::Types::THINKING, thinking[:type]
    assert_equal "weighing the options", thinking[:text]
  end

  # A `!`-prefixed shell command the USER ran. Not a model tool call, but it is
  # conversation the user expects to see.
  test "a bashExecution entry becomes a ToolCall and ToolResult pair" do
    raw = {
      "type" => "message", "id" => "cafebabe", "timestamp" => "2026-09-01T10:00:00.000Z",
      "message" => {
        "role" => "bashExecution", "command" => "ls -la", "output" => "total 0",
        "exitCode" => 0, "cancelled" => false, "truncated" => false
      }
    }

    call, result = @normalizer.normalize(raw, session: @session, transcript_index: 0)

    assert_equal OpenTranscript::Types::TOOL_CALL, call[:type]
    assert_equal "bash", call[:tool_name]
    assert_equal({ "command" => "ls -la" }, call[:arguments])
    assert_equal OpenTranscript::Types::TOOL_RESULT, result[:type]
    assert_equal call[:tool_call_id], result[:tool_call_id]
    assert_equal "total 0", result[:output].first["text"]
    assert_not result[:is_error]
  end

  test "a non-zero bashExecution exit marks the result as an error" do
    raw = {
      "type" => "message", "id" => "cafed00d", "timestamp" => "2026-09-01T10:00:00.000Z",
      "message" => { "role" => "bashExecution", "command" => "false", "output" => "", "exitCode" => 1 }
    }

    _call, result = @normalizer.normalize(raw, session: @session, transcript_index: 0)

    assert result[:is_error]
  end

  test "a compaction entry becomes a Compaction event" do
    raw = {
      "type" => "compaction", "id" => "0badf00d", "timestamp" => "2026-09-01T10:00:00.000Z",
      "summary" => "Earlier turns summarized", "tokensBefore" => 50_000
    }

    event = @normalizer.normalize(raw, session: @session, transcript_index: 0).sole

    assert_equal OpenTranscript::Types::COMPACTION, event[:type]
    assert_equal "Earlier turns summarized", event[:summary]
    assert_equal 50_000, event[:tokens_before]
  end

  # Extension-injected context is not something the human said, so attributing it
  # to the user would be wrong.
  test "an extension-injected custom_message becomes a SystemEvent naming the extension" do
    raw = {
      "type" => "custom_message", "id" => "feedface", "timestamp" => "2026-09-01T10:00:00.000Z",
      "customType" => "pi-hooks", "content" => "injected by a hook", "display" => true
    }

    event = @normalizer.normalize(raw, session: @session, transcript_index: 0).sole

    assert_equal OpenTranscript::Types::SYSTEM_EVENT, event[:type]
    assert_equal "pi-hooks", event[:subtype]
  end

  test "normalize tolerates a non-Hash record" do
    assert_equal [], @normalizer.normalize("not a hash", session: @session, transcript_index: 0)
  end

  private

  # Normalize the fixture entry at `index`, returning its events.
  def normalize_message_at(index)
    @normalizer.normalize(@events[index], session: @session, transcript_index: index)
  end
end
