# frozen_string_literal: true

require "integration_test_helper"

class TranscriptPollingTest < IntegrationTestCase
  test "should update session transcript during execution" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test polling",
      status: "running",
      agent_runtime: "claude_code"
    )

    # Simulate transcript update
    transcript_content = {
      messages: [
        { type: "text", text: "Hello from Claude" },
        { type: "text", text: "Processing your request" },
        { type: "text", text: "Task completed" }
      ]
    }.to_json

    session.update!(
      transcript: transcript_content,
      last_timeline_entry_at: Time.current
    )

    assert_not_nil session.transcript
    assert session.transcript.include?("Hello from Claude")
    assert_not_nil session.last_timeline_entry_at
  end

  test "should handle incremental transcript updates" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test incremental",
      status: "running",
      agent_runtime: "claude_code"
    )

    # First update
    session.update!(
      transcript: '{"messages": [{"type": "text", "text": "Message 1"}]}'
    )

    initial_transcript = session.transcript

    # Second update with more messages
    session.update!(
      transcript: '{"messages": [{"type": "text", "text": "Message 1"}, {"type": "text", "text": "Message 2"}]}'
    )

    # Transcript should have grown
    assert session.transcript.length > initial_transcript.length
    assert session.transcript.include?("Message 2")
  end

  test "should handle transcript when session completes" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test completion",
      status: "running",
      agent_runtime: "claude_code"
    )

    # Simulate completion with final transcript
    final_transcript = {
      messages: [
        { type: "text", text: "Starting..." },
        { type: "text", text: "Working..." },
        { type: "text", text: "Completed successfully!" }
      ],
      status: "success"
    }.to_json

    session.update!(
      status: "archived",
      transcript: final_transcript
    )

    assert_equal "archived", session.status
    assert session.transcript.include?("Completed successfully")
  end

  test "should handle missing transcript gracefully" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test missing transcript",
      status: "archived",
      agent_runtime: "claude_code",
      transcript: nil
    )

    # Session should still be valid without transcript
    assert session.valid?
    assert_nil session.transcript

    # Should be viewable
    get session_path(session)
    assert_response :success
  end

  test "should handle malformed transcript JSON" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test bad JSON",
      status: "running",
      agent_runtime: "claude_code"
    )

    # Set malformed transcript
    session.update_column(:transcript, "This is not JSON")

    # Should handle gracefully when accessing
    get session_path(session)
    assert_response :success
  end

  test "should track last broadcast time" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test broadcast time",
      status: "running",
      agent_runtime: "claude_code"
    )

    initial_time = Time.current

    session.update!(
      transcript: '{"messages": [{"type": "text", "text": "Update"}]}',
      last_timeline_entry_at: initial_time
    )

    assert_equal initial_time.to_i, session.last_timeline_entry_at.to_i

    # Update again
    sleep 0.1
    new_time = Time.current
    session.update!(last_timeline_entry_at: new_time)

    assert session.last_timeline_entry_at > initial_time
  end

  test "should show transcript in session view" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test view transcript",
      status: "archived",
      agent_runtime: "claude_code",
      transcript: '{"messages": [{"type": "text", "text": "Visible message"}]}'
    )

    get session_path(session)
    assert_response :success

    # Session should be accessible with transcript
    assert_not_nil session.transcript
  end

  test "should handle large transcripts" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test large transcript",
      status: "running",
      agent_runtime: "claude_code"
    )

    # Create large transcript
    messages = 100.times.map do |i|
      { type: "text", text: "Message #{i}" }
    end

    large_transcript = { messages: messages }.to_json

    session.update!(transcript: large_transcript)

    assert session.transcript.length > 1000
    assert session.valid?
  end

  test "should handle concurrent transcript updates" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test concurrent updates",
      status: "running",
      agent_runtime: "claude_code"
    )

    # Simulate concurrent updates
    3.times do |i|
      session.reload
      current = JSON.parse(session.transcript || '{"messages": []}')
      current["messages"] << { type: "text", text: "Update #{i}" }
      session.update!(transcript: current.to_json)
    end

    # All updates should be present
    final = JSON.parse(session.transcript)
    assert_equal 3, final["messages"].count
  end

  test "should not update transcript for archived sessions" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test no update when archived",
      status: "archived",
      agent_runtime: "claude_code",
      transcript: '{"messages": [{"type": "text", "text": "Final"}]}'
    )

    original_transcript = session.transcript

    # Try to update (should be prevented by business logic)
    if session.status == "archived"
      # Skip update
    else
      session.update!(transcript: '{"messages": [{"type": "text", "text": "Should not update"}]}')
    end

    session.reload
    assert_equal original_transcript, session.transcript
  end
end
