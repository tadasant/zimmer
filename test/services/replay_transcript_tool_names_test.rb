# frozen_string_literal: true

require "test_helper"

# #1603: the stored transcript of session 29423 held this name in a
# tool_reference, a tool_use and a deferred_tools_delta attachment, and every
# status-summary fork of it got a 400 from the API.
class ReplayTranscriptToolNamesTest < ActiveSupport::TestCase
  VALID = /\A[a-zA-Z0-9_-]{1,128}\z/
  REDACTED_NAME = "mcp__zimmer__compare_github_[REDACTED:ENV:GITHUB_TRIGGER_INGEST_MODE:14ch]"
  REPAIRED_NAME = "mcp__zimmer__compare_github_REDACTED"

  # Entry shapes copied from Claude Code 2.1.330 transcripts.
  def transcript
    [
      { "type" => "attachment", "uuid" => "a1", "attachment" => {
        "type" => "deferred_tools_delta",
        "addedNames" => [ "WebFetch", REDACTED_NAME ],
        "addedLines" => [ "WebFetch", REDACTED_NAME ],
        "removedNames" => [], "wireHiddenNames" => [], "readdedNames" => [], "pendingMcpServers" => []
      } },
      { "type" => "assistant", "uuid" => "a2", "message" => { "role" => "assistant", "content" => [
        { "type" => "tool_use", "id" => "toolu_1", "name" => "ToolSearch", "input" => { "query" => "select:#{REDACTED_NAME}" } }
      ] } },
      { "type" => "user", "uuid" => "a3", "message" => { "role" => "user", "content" => [
        { "type" => "tool_result", "tool_use_id" => "toolu_1", "content" => [
          { "type" => "tool_reference", "tool_name" => REDACTED_NAME }
        ] }
      ] } },
      { "type" => "assistant", "uuid" => "a4", "message" => { "role" => "assistant", "content" => [
        { "type" => "tool_use", "id" => "toolu_2", "name" => REDACTED_NAME, "input" => {} }
      ] } },
      { "type" => "user", "uuid" => "a5", "message" => { "role" => "user", "content" => [
        { "type" => "tool_result", "tool_use_id" => "toolu_2", "content" => "mode [REDACTED:ENV:GITHUB_TRIGGER_INGEST_MODE:14ch]" }
      ] } }
    ].map { |entry| JSON.generate(entry) }.join("\n") + "\n"
  end

  def tool_names(jsonl)
    jsonl.each_line.flat_map do |line|
      entry = JSON.parse(line)
      delta = entry["attachment"] || {}
      blocks = Array(entry.dig("message", "content")).flat_map { |b| [ b, *Array(b["content"]).grep(Hash) ] }
      ReplayTranscriptToolNames::DEFERRED_TOOL_LISTS.flat_map { |k| Array(delta[k]) } +
        blocks.filter_map { |b| b["type"] == "tool_use" ? b["name"] : (b["type"] == "tool_reference" ? b["tool_name"] : nil) }
    end
  end

  test "every tool name a replay sends is inside the API's grammar after repair" do
    refute tool_names(transcript).all? { |name| name.match?(VALID) }, "the fixture reproduces the 400"

    repaired = ReplayTranscriptToolNames.repair(transcript)

    names = tool_names(repaired)
    assert names.all? { |name| name.match?(VALID) }, names.inspect
    assert_equal 4, names.count(REPAIRED_NAME), "the same redacted name repairs to the same string everywhere"
  end

  test "only names are repaired: tool inputs and results keep their markers, and lines and terminators are kept" do
    repaired = ReplayTranscriptToolNames.repair(transcript)

    assert_equal transcript.lines.count, repaired.lines.count
    assert repaired.end_with?("\n")
    assert_includes repaired, %("query":"select:#{REDACTED_NAME}"), "a tool input is not a name"
    assert_includes repaired, "mode [REDACTED:ENV:GITHUB_TRIGGER_INGEST_MODE:14ch]", "a tool result is not a name"
    assert_includes repaired, %("name":"ToolSearch")
  end

  test "a transcript without a marker, and lines without one, come back byte for byte" do
    clean = %({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"cmd":"echo \\u00e9"}}]}}\n)
    assert_same clean, ReplayTranscriptToolNames.repair(clean)

    mixed = clean + transcript
    assert ReplayTranscriptToolNames.repair(mixed).start_with?(clean)
  end

  test "an unparseable line holding a marker is left alone, and nil passes through" do
    broken = "{not json [REDACTED:ENV:X:14ch]\n"
    assert_equal broken, ReplayTranscriptToolNames.repair(broken)
    assert_nil ReplayTranscriptToolNames.repair(nil)
  end

  test "a repaired name is capped at the grammar's 128 characters" do
    name = "mcp__#{'a' * 120}_[REDACTED:ENV:FIXTURE:14ch]"
    assert_match VALID, ReplayTranscriptToolNames.repair_name(name)
  end
end
