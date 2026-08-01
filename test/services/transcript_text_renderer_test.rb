# frozen_string_literal: true

require "test_helper"

class TranscriptTextRendererTest < ActiveSupport::TestCase
  test "renders plain string content" do
    text = TranscriptTextRenderer.render([
      { "type" => "user", "message" => { "role" => "user", "content" => "hello" } },
      { "type" => "assistant", "message" => { "role" => "assistant", "content" => "hi back" } }
    ])

    assert_includes text, "--- User ---"
    assert_includes text, "hello"
    assert_includes text, "--- Assistant ---"
    assert_includes text, "hi back"
  end

  # The bug this class exists to kill: `content` is frequently an array of
  # content blocks, and pushing it into the line list left `join` to `to_s` each
  # Hash into the output.
  test "renders an array of content blocks rather than stringifying it" do
    text = TranscriptTextRenderer.render([
      {
        "type" => "assistant",
        "message" => {
          "role" => "assistant",
          "content" => [
            { "type" => "text", "text" => "first" },
            { "type" => "thinking", "thinking" => "second" },
            { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/app/x.rb" } },
            { "type" => "image" }
          ]
        }
      }
    ])

    refute_includes text, '"type"=>'
    assert_includes text, "first"
    assert_includes text, "[thinking] second"
    assert_includes text, '[tool_use: Read] {"file_path":"/app/x.rb"}'
    assert_includes text, "[image]"
  end

  test "renders a nested tool_result block" do
    text = TranscriptTextRenderer.render([
      {
        "type" => "user",
        "message" => {
          "role" => "user",
          "content" => [ { "type" => "tool_result", "content" => [ { "type" => "text", "text" => "the file" } ] } ]
        }
      }
    ])

    assert_includes text, "[tool_result] the file"
  end

  test "labels an unknown block type as pretty JSON" do
    text = TranscriptTextRenderer.render([
      { "type" => "assistant", "message" => { "content" => [ { "type" => "future_block", "payload" => 1 } ] } }
    ])

    assert_includes text, "future_block"
    refute_includes text, "=>"
  end

  # Every entry is rendered — the old `case` fell through silently on anything
  # it did not name, so the text transcript disagreed with the raw one.
  test "labels and dumps entry types with no special layout" do
    text = TranscriptTextRenderer.render([
      { "type" => "system", "content" => "session resumed" },
      { "type" => "result", "subtype" => "success", "total_cost_usd" => 0.42 },
      { "type" => "summary", "summary" => "did the thing" }
    ])

    assert_includes text, "--- System ---"
    assert_includes text, "session resumed"
    assert_includes text, "--- Result ---"
    assert_includes text, "total_cost_usd"
    assert_includes text, "--- Summary ---"
    assert_includes text, "did the thing"
  end

  test "names the role on an unknown type when the entry carries one" do
    text = TranscriptTextRenderer.render([
      { "type" => "progress", "role" => "assistant", "content" => "working" }
    ])

    assert_includes text, "--- Progress (assistant) ---"
  end

  test "truncates a long tool result" do
    text = TranscriptTextRenderer.render([ { "type" => "tool_result", "content" => "x" * 5_000 } ])

    assert_includes text, "--- Tool Result ---"
    assert_operator text.length, :<, 700
  end

  test "renders a tool_use entry from its input" do
    text = TranscriptTextRenderer.render([
      { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "ls" } }
    ])

    assert_includes text, "--- Tool Use: Bash ---"
    assert_includes text, "ls"
  end

  test "survives a non-Hash entry" do
    assert_includes TranscriptTextRenderer.render([ "not an entry" ]), "--- Unknown ---"
  end

  test "renders nothing for no entries" do
    assert_equal "", TranscriptTextRenderer.render(nil)
    assert_equal "", TranscriptTextRenderer.render([])
  end
end
