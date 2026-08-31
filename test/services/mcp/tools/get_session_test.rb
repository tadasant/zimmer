# frozen_string_literal: true

require "test_helper"


class Mcp::Tools::GetSessionTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::GetSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  test "returns session details and the transcript file hint instead of the transcript" do
    session = sessions(:archived)

    output = @tool.call("id" => session.id)

    assert_includes output, "## Session: #{session.title}"
    assert_includes output, "- **ID:** #{session.id}"
    assert_includes output, "- **Status:** archived"
    assert_includes output, "### Transcript File"
    assert_includes output, "`~/.claude/projects/*/#{session.session_id}.jsonl`"
    refute_includes output, "I've completed the task for you."
  end

  test "include_transcript inlines the raw transcript and drops the file hint" do
    session = sessions(:archived)

    output = @tool.call("id" => session.id, "include_transcript" => true)

    assert_includes output, "### Transcript"
    assert_includes output, "I've completed the task for you."
    refute_includes output, "### Transcript File"
  end

  test "transcript_format renders the formatted transcript" do
    session = sessions(:archived)

    output = @tool.call("id" => session.id, "include_transcript" => true, "transcript_format" => "text")

    assert_includes output, "--- User ---"
    assert_includes output, "--- Assistant ---"
    assert_includes output, "I've completed the task for you."
  end

  test "transcript_format raises when there is no transcript" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("id" => sessions(:running).id, "include_transcript" => true, "transcript_format" => "json")
    end
    assert_match(/No transcript available/, error.message)
  end

  test "include_logs paginates the session logs" do
    session = sessions(:running)

    output = @tool.call("id" => session.id, "include_logs" => true)

    assert_includes output, "### Logs (#{session.logs.count} total, page 1 of 1)"
    assert_includes output, "**[INFO]**"
    assert_includes output, "Agent started successfully"

    paged = @tool.call("id" => session.id, "include_logs" => true, "logs_per_page" => 1)
    assert_includes paged, "*More logs available. Use logs_page=2 to see the next page.*"
  end

  test "include_subagent_transcripts reports an empty list" do
    output = @tool.call("id" => sessions(:running).id, "include_subagent_transcripts" => true)

    assert_includes output, "### Subagent Transcripts (0 total, page 1 of 0)"
    assert_includes output, "No subagent transcripts found."
  end

  test "session can be addressed by slug" do
    session = sessions(:running)
    session.update!(slug: "mcp-get-session-slug")

    output = @tool.call("id" => "mcp-get-session-slug")

    assert_includes output, "- **ID:** #{session.id}"
    assert_includes output, "- **Slug:** mcp-get-session-slug"
  end

  test "missing session raises a tool error" do
    assert_raises(Mcp::ToolError) { @tool.call("id" => 999_999) }
    assert_raises(Mcp::ToolError) { @tool.call({}) }
  end

  # An agent reading its own session has to be able to tell a deferred turn from a
  # stuck one — and, when the gate refused a WAKE rather than a first start, that
  # the prompt it was woken for is still coming.
  test "a spot session held before its next turn says so, and says the prompt survives" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, metadata: {
      SpotSessionHold::HELD_REASON => "at_utilization_limit",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5-hour window at 87% of its 65% target.",
      SpotSessionHold::HELD_AT => 20.minutes.ago.utc.iso8601,
      SpotSessionHold::HELD_RETRY_AT => 40.minutes.from_now.utc.iso8601,
      SpotSessionHold::HELD_COUNT => 3,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_RESUME
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "**Spot gate: next turn held (`at_utilization_limit`):**"
    assert_includes output, "- **Hold re-check:** Next check"
    assert_includes output, "- **Holds so far:** 3"
    assert_includes output, "The prompt that woke it is not lost"
  end

  # The detail above is a SNAPSHOT of what the gate said at `spot_hold_at`, and an
  # agent reading its own session had no way to tell. Session 7507 read back "5 of
  # 5 session slots taken" eleven hours after the gate had returned to
  # `within_limits` at 1 of 5 — the same fossil the session page showed, in the
  # same words, which is why both surfaces now render it from one object.
  test "a held session says how old the gate reading is, and names an overdue re-check" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, metadata: {
      SpotSessionHold::HELD_AT => 11.hours.ago.utc.iso8601,
      SpotSessionHold::HELD_REASON => "fleet_at_cap",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5 of 5 session slots taken.",
      SpotSessionHold::HELD_RETRY_AT => 10.hours.ago.utc.iso8601,
      SpotSessionHold::HELD_COUNT => 145,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_RESUME
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "- **As of:** That was the gate's reading about 11 hours ago"
    assert_includes output, "not a live one"
    assert_includes output, "Its re-check was due about 10 hours ago"
    assert_includes output, "has not fired, so the ladder has stalled"
    refute_includes output, "Hold re-check:** Next check"
  end

  test "a spot session held at the starting line does not claim a queued prompt" do
    session = sessions(:running)
    session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, metadata: {
      SpotSessionHold::HELD_REASON => "fleet_at_cap",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 10 of 10 session slots taken.",
      SpotSessionHold::HELD_COUNT => 1,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START
    })

    output = @tool.call("id" => session.id)

    assert_includes output, "**Spot gate: start held (`fleet_at_cap`):**"
    refute_includes output, "The prompt that woke it is not lost"
  end
end
