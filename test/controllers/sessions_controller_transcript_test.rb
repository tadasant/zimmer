require "test_helper"

# Integration coverage for transcript rendering on the session show page.
#
# Both runtimes normalize their native JSONL into OpenTranscripts v0.1 events
# (see OpenTranscript / https://docs.zimmer.tadasant.com/sessions/transcripts/). Every event renders through
# the single timeline_items/_item partial, keyed on the event :type. These
# tests drive that path end-to-end through the controller, using realistic
# Claude Code JSONL lines (a top-level "type" with a nested "message" envelope).
#
# Filter levels (SessionsController#item_visible_for_filter?):
#   minimal   -> only "message" category (UserMessage/AssistantMessage/...)
#   condensed -> + "tool-message" (ToolCall/ToolResult/Thinking/SubagentSpawn)
# Tool calls/results are hidden at the default "minimal" level, so tests that
# assert on tool rows request ?filter=condensed.
class SessionsControllerTranscriptTest < ActionDispatch::IntegrationTest
  test "should render the timeline section on show page" do
    session = sessions(:running)
    get session_url(session)

    assert_response :success
    assert_match(/Log Level:/, response.body)
    assert_select "#timeline-container"
  end

  test "should display running empty state when transcript is empty" do
    session = sessions(:running)
    get session_url(session)

    assert_response :success
    assert_match(/Agent is running/, response.body)
    assert_match(/conversation and activity will appear here/, response.body)
  end

  test "should display non-running empty state when transcript is empty" do
    session = sessions(:needs_input)
    get session_url(session)

    assert_response :success
    assert_match(/No activity yet/, response.body)
    assert_match(/conversation and activity logs will appear here/, response.body)
  end

  test "should display transcript messages when transcript exists" do
    session = sessions(:with_transcript)
    get session_url(session)

    assert_response :success
    assert_match(/Hello, can you help me\?/, response.body)
    assert_match(/Of course!/, response.body)
    assert_match(/happy to help/, response.body)
    assert_match(/I need to create a new feature/, response.body)
  end

  test "should show item count when transcript exists" do
    session = sessions(:with_transcript)
    get session_url(session)

    assert_response :success
    # Three message events, all visible at the default minimal filter level.
    assert_match(/3 items/, response.body)
  end

  test "should display role indicators in transcript" do
    session = sessions(:with_transcript)
    get session_url(session)

    assert_response :success
    assert_match(/User/, response.body)
    assert_match(/Assistant/, response.body)
  end

  test "should sanitize transcript content to prevent XSS" do
    session = sessions(:running)
    session.update!(transcript: [
      {
        "type" => "user",
        "timestamp" => "2025-11-12T12:00:00Z",
        "message" => { "role" => "user", "content" => "<script>alert('XSS')</script>Hello" }
      }
    ])

    get session_url(session)

    assert_response :success
    # The raw, executable <script> tag must not survive into the rendered page.
    assert_no_match(/<script>alert/, response.body)
    # The payload is HTML-escaped and rendered as inert text
    # (&lt;script&gt;alert(&#39;XSS&#39;)&lt;/script&gt;Hello).
    assert_match(/&lt;script&gt;alert/, response.body)
    assert_match(/XSS.*Hello/, response.body)
  end

  test "should render content despite an invalid timestamp" do
    session = sessions(:running)
    session.update!(transcript: [
      {
        "type" => "user",
        "timestamp" => "not-a-valid-timestamp",
        "message" => { "role" => "user", "content" => "Hello despite bad timestamp" }
      }
    ])

    get session_url(session)

    # An unparseable ts falls back to the session's created_at (events never
    # carry a null ts), so the message still renders.
    assert_response :success
    assert_match(/Hello despite bad timestamp/, response.body)
  end

  test "should handle missing timestamp field" do
    session = sessions(:running)
    session.update!(transcript: [
      {
        "type" => "user",
        "message" => { "role" => "user", "content" => "Hello without timestamp" }
      }
    ])

    get session_url(session)

    assert_response :success
    assert_match(/Hello without timestamp/, response.body)
  end

  test "should display tool usage with parameters" do
    session = sessions(:running)
    session.update!(transcript: [
      {
        "type" => "assistant",
        "timestamp" => "2025-11-12T12:00:00Z",
        "message" => {
          "role" => "assistant",
          "content" => [
            { "type" => "text", "text" => "I'll create a todo list for this task." },
            {
              "type" => "tool_use",
              "id" => "toolu_123",
              "name" => "TodoWrite",
              "input" => {
                "todos" => [
                  { "content" => "Fix bug in login", "status" => "pending" },
                  { "content" => "Add tests", "status" => "pending" }
                ]
              }
            }
          ]
        }
      }
    ])

    get session_url(session, filter: "condensed")

    assert_response :success
    # Assistant text is a "message" event; the tool row is a "tool-message".
    # (Apostrophes are HTML-escaped by the markdown renderer, so match a
    # substring without one.)
    assert_match(/create a todo list for this task/, response.body)
    assert_match(/Using tool: TodoWrite/, response.body)
    assert_match(/Parameters:/, response.body)
    assert_match(/todos:/, response.body)
  end

  test "should display tool results" do
    session = sessions(:running)
    session.update!(transcript: [
      {
        "type" => "user",
        "timestamp" => "2025-11-12T12:00:00Z",
        "message" => {
          "role" => "user",
          "content" => [
            {
              "type" => "tool_result",
              "tool_use_id" => "toolu_456",
              "content" => "File content:\nHello, world!"
            }
          ]
        }
      }
    ])

    get session_url(session, filter: "condensed")

    assert_response :success
    assert_match(/Tool Result/, response.body)
    assert_match(/File content:/, response.body)
    assert_match(/Hello, world!/, response.body)
  end

  test "should display multiple content blocks" do
    session = sessions(:running)
    session.update!(transcript: [
      {
        "type" => "assistant",
        "timestamp" => "2025-11-12T12:00:00Z",
        "message" => {
          "role" => "assistant",
          "content" => [
            { "type" => "text", "text" => "First, I'll read the file." },
            {
              "type" => "tool_use",
              "id" => "toolu_789",
              "name" => "Read",
              "input" => { "file_path" => "/path/to/file.rb" }
            },
            { "type" => "text", "text" => "Now I'll analyze it." }
          ]
        }
      }
    ])

    get session_url(session, filter: "condensed")

    assert_response :success
    # Apostrophes are HTML-escaped, so match substrings without one.
    assert_match(/read the file/, response.body)
    assert_match(%r{Using tool: Read}, response.body)
    assert_match(%r{file_path: /path/to/file\.rb}, response.body)
    assert_match(/analyze it/, response.body)
  end

  test "should handle tool usage without parameters" do
    session = sessions(:running)
    session.update!(transcript: [
      {
        "type" => "assistant",
        "timestamp" => "2025-11-12T12:00:00Z",
        "message" => {
          "role" => "assistant",
          "content" => [
            {
              "type" => "tool_use",
              "id" => "toolu_empty",
              "name" => "WebSearch",
              "input" => {}
            }
          ]
        }
      }
    ])

    get session_url(session, filter: "condensed")

    assert_response :success
    assert_match(/Using tool: WebSearch/, response.body)
    # No Parameters section when the tool has no arguments.
    assert_no_match(/Parameters:/, response.body)
  end

  # Regression for the OpenTranscripts refactor (PR #3942 / commit 0a00cec4):
  # an assistant line carrying only tool_use/thinking blocks (no text) normalizes
  # into a content-less AssistantMessage that must NOT surface as a bare
  # "Assistant" row, while its Thinking/ToolCall rows still render.
  test "should not render an empty Assistant row for a text-less assistant line" do
    session = sessions(:running)
    session.update!(transcript: [
      {
        "type" => "assistant",
        "timestamp" => "2025-11-12T12:00:00Z",
        "message" => {
          "role" => "assistant",
          "content" => [
            { "type" => "thinking", "thinking" => "Let me search for that." },
            {
              "type" => "tool_use",
              "id" => "toolu_textless",
              "name" => "WebSearch",
              "input" => { "query" => "open transcripts" }
            }
          ]
        }
      }
    ])

    get session_url(session, filter: "condensed")

    assert_response :success
    # The Thinking and ToolCall rows still render...
    assert_select "p.text-sm.font-medium.text-gray-900", text: "Thinking", count: 1
    assert_select "p.text-sm.font-medium.text-gray-900", text: "Tool: WebSearch", count: 1
    # ...but no standalone "Assistant" header row is drawn for the empty message.
    assert_select "p.text-sm.font-medium.text-gray-900", text: "Assistant", count: 0
    # The empty AssistantMessage is also excluded from the visible item count:
    # only the Thinking + ToolCall events are counted (2 items), not 3.
    assert_match(/2 items/, response.body)
  end

  test "should still render Assistant rows for text-bearing assistant lines" do
    session = sessions(:running)
    session.update!(transcript: [
      {
        "type" => "assistant",
        "timestamp" => "2025-11-12T12:00:00Z",
        "message" => {
          "role" => "assistant",
          "content" => [
            { "type" => "text", "text" => "Here is my answer." },
            {
              "type" => "tool_use",
              "id" => "toolu_withtext",
              "name" => "WebSearch",
              "input" => { "query" => "open transcripts" }
            }
          ]
        }
      }
    ])

    get session_url(session, filter: "condensed")

    assert_response :success
    assert_select "p.text-sm.font-medium.text-gray-900", text: "Assistant", count: 1
    assert_match(/Here is my answer/, response.body)
    assert_select "p.text-sm.font-medium.text-gray-900", text: "Tool: WebSearch", count: 1
  end
end
