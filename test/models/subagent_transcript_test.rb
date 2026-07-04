# frozen_string_literal: true

require "test_helper"

class SubagentTranscriptTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
  end

  test "belongs to session" do
    subagent = SubagentTranscript.new(agent_id: "agent-abc123", session: @session)
    assert_equal @session, subagent.session
  end

  test "requires agent_id" do
    subagent = SubagentTranscript.new(session: @session)
    assert_not subagent.valid?
    assert_includes subagent.errors[:agent_id], "can't be blank"
  end

  test "requires unique agent_id per session" do
    SubagentTranscript.create!(session: @session, agent_id: "agent-unique1")

    duplicate = SubagentTranscript.new(session: @session, agent_id: "agent-unique1")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:agent_id], "has already been taken"
  end

  test "allows same agent_id for different sessions" do
    other_session = sessions(:waiting)

    SubagentTranscript.create!(session: @session, agent_id: "agent-shared")
    other_subagent = SubagentTranscript.new(session: other_session, agent_id: "agent-shared")

    assert other_subagent.valid?
  end

  test "parsed_transcript returns empty array when transcript is nil" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test")
    assert_equal [], subagent.parsed_transcript
  end

  test "parsed_transcript returns empty array when transcript is empty" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", transcript: "")
    assert_equal [], subagent.parsed_transcript
  end

  test "parsed_transcript parses JSONL content" do
    transcript_content = <<~JSONL
      {"type": "user", "message": {"role": "user", "content": "Hello"}}
      {"type": "assistant", "message": {"role": "assistant", "content": "Hi there"}}
    JSONL

    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", transcript: transcript_content)
    result = subagent.parsed_transcript

    assert_equal 2, result.length
    assert_equal "user", result[0]["type"]
    assert_equal "assistant", result[1]["type"]
  end

  test "parsed_transcript skips invalid JSON lines" do
    transcript_content = <<~JSONL
      {"type": "user", "message": {"role": "user", "content": "Hello"}}
      invalid json line
      {"type": "assistant", "message": {"role": "assistant", "content": "Hi"}}
    JSONL

    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", transcript: transcript_content)
    result = subagent.parsed_transcript

    assert_equal 2, result.length
  end

  test "parsed_transcript skips empty lines" do
    transcript_content = <<~JSONL
      {"type": "user"}

      {"type": "assistant"}

    JSONL

    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", transcript: transcript_content)
    result = subagent.parsed_transcript

    assert_equal 2, result.length
  end

  test "session can have many subagent_transcripts" do
    # Create a fresh session to avoid fixture interference
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      status: :running,
      prompt: "Test",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    SubagentTranscript.create!(session: session, agent_id: "agent-1")
    SubagentTranscript.create!(session: session, agent_id: "agent-2")

    session.reload
    assert_equal 2, session.subagent_transcripts.count
  end

  test "subagent_transcripts are destroyed with session" do
    # Create a fresh session to avoid fixture interference
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      status: :running,
      prompt: "Test",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    SubagentTranscript.create!(session: session, agent_id: "agent-to-destroy")

    assert_difference "SubagentTranscript.count", -1 do
      session.destroy
    end
  end

  # === Status helper methods ===

  test "running? returns true when status is running" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", status: "running")
    assert subagent.running?
    assert_not subagent.completed?
    assert_not subagent.failed?
  end

  test "completed? returns true when status is completed" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", status: "completed")
    assert subagent.completed?
    assert_not subagent.running?
    assert_not subagent.failed?
  end

  test "failed? returns true when status is failed" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", status: "failed")
    assert subagent.failed?
    assert_not subagent.running?
    assert_not subagent.completed?
  end

  test "status helpers return false when status is nil" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", status: nil)
    assert_not subagent.running?
    assert_not subagent.completed?
    assert_not subagent.failed?
  end

  # === formatted_duration tests ===

  test "formatted_duration returns nil when duration_ms is nil" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test")
    assert_nil subagent.formatted_duration
  end

  test "formatted_duration formats seconds only for short durations" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", duration_ms: 45_000)
    assert_equal "45s", subagent.formatted_duration
  end

  test "formatted_duration formats minutes and seconds for longer durations" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", duration_ms: 125_000)
    assert_equal "2m 5s", subagent.formatted_duration
  end

  test "formatted_duration handles zero duration" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", duration_ms: 0)
    assert_equal "0s", subagent.formatted_duration
  end

  test "formatted_duration handles sub-second durations" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", duration_ms: 500)
    assert_equal "0s", subagent.formatted_duration
  end

  # === formatted_tokens tests ===

  test "formatted_tokens returns nil when total_tokens is nil" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test")
    assert_nil subagent.formatted_tokens
  end

  test "formatted_tokens returns number for tokens under 1000" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", total_tokens: 500)
    assert_equal "500", subagent.formatted_tokens
  end

  test "formatted_tokens formats thousands with k suffix" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", total_tokens: 1500)
    assert_equal "1.5k", subagent.formatted_tokens
  end

  test "formatted_tokens handles exactly 1000 tokens" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", total_tokens: 1000)
    assert_equal "1.0k", subagent.formatted_tokens
  end

  test "formatted_tokens handles zero tokens" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", total_tokens: 0)
    assert_equal "0", subagent.formatted_tokens
  end

  # === display_label tests ===

  test "display_label returns description when present" do
    subagent = SubagentTranscript.new(
      session: @session,
      agent_id: "agent-test",
      description: "Find user model",
      subagent_type: "Explore"
    )
    assert_equal "Find user model", subagent.display_label
  end

  test "display_label returns subagent_type when description is blank" do
    subagent = SubagentTranscript.new(
      session: @session,
      agent_id: "agent-test",
      description: "",
      subagent_type: "Explore"
    )
    assert_equal "Explore", subagent.display_label
  end

  test "display_label returns Subagent when both are blank" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test")
    assert_equal "Subagent", subagent.display_label
  end

  # === Status validation ===

  test "validates status inclusion" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-test", status: "invalid")
    assert_not subagent.valid?
    assert_includes subagent.errors[:status], "is not included in the list"
  end

  test "allows valid status values" do
    %w[running completed failed].each do |status|
      subagent = SubagentTranscript.new(session: @session, agent_id: "agent-#{status}", status: status)
      assert subagent.valid?, "Status '#{status}' should be valid"
    end
  end

  test "allows nil status" do
    subagent = SubagentTranscript.new(session: @session, agent_id: "agent-nil-status", status: nil)
    assert subagent.valid?
  end
end
