require "application_system_test_case"

class TranscriptParityTest < ApplicationSystemTestCase
  # Test that the timeline content shown via Turbo Stream broadcasts
  # is identical to what's rendered on page refresh
  #
  # This verifies the fix for the issue where live updates showed different
  # content than a full page reload
  test "timeline content is identical between live updates and page refresh" do
    # Create a session with a JSONL transcript (not legacy array format)
    # This simulates what AgentSessionJob would create
    jsonl_transcript = <<~JSONL.strip
      {"type":"user","message":{"role":"user","content":"Hello, can you help me?"},"timestamp":"2025-11-12T12:00:00Z"}
      {"type":"assistant","message":{"role":"assistant","content":"Of course! I'd be happy to help."},"timestamp":"2025-11-12T12:00:05Z"}
      {"type":"user","message":{"role":"user","content":"I need to create a new feature"},"timestamp":"2025-11-12T12:00:10Z"}
    JSONL

    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test parity",
      status: :archived, # Use archived so it won't try to start more jobs
      agent_runtime: "claude_code",
      branch: "main",
      transcript: jsonl_transcript,
      metadata: { "broadcast_message_count" => 3 } # All 3 messages were broadcast
    )

    # Also create some logs to verify they render consistently too
    session.logs.create!(content: "Starting session", level: "info", created_at: Time.parse("2025-11-12T11:59:55Z"))
    session.logs.create!(content: "Session completed", level: "info", created_at: Time.parse("2025-11-12T12:00:15Z"))

    # Visit the session page with verbose filter to see logs
    # (default "minimal" filter hides logs)
    visit session_path(session, filter: "verbose")

    # Wait for page to fully load
    assert_selector "[data-controller='transcript-copy'] button[aria-label='Copy full transcript to clipboard']"

    # Extract the timeline HTML (everything inside the timeline container)
    # We'll normalize timestamps since those update dynamically
    timeline_html_initial = extract_normalized_timeline_html

    # Verify we have content
    assert timeline_html_initial.include?("Hello, can you help me?"), "Should show user message"
    assert timeline_html_initial.include?("Of course! I'd be happy to help"), "Should show assistant message"
    assert timeline_html_initial.include?("Starting session"), "Should show logs"
    assert timeline_html_initial.include?("Session completed"), "Should show logs"

    # Now refresh the page (with same filter)
    visit session_path(session, filter: "verbose")

    # Wait for page to fully load again
    assert_selector "[data-controller='transcript-copy'] button[aria-label='Copy full transcript to clipboard']"

    # Extract the timeline HTML again
    timeline_html_after_refresh = extract_normalized_timeline_html

    # The HTML should be identical (ignoring timestamp text changes)
    assert_equal timeline_html_initial, timeline_html_after_refresh,
                 "Timeline HTML should be identical before and after refresh"
  end

  test "timeline with tool use renders consistently on refresh" do
    # Create a session with tool use in the transcript
    jsonl_transcript = <<~JSONL.strip
      {"type":"user","message":{"role":"user","content":"Read the README file"},"timestamp":"2025-11-12T12:00:00Z"}
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_123","name":"Read","input":{"file_path":"/path/to/README.md"}}]},"timestamp":"2025-11-12T12:00:05Z"}
      {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_123","content":"# README\\n\\nThis is a test file"}]},"timestamp":"2025-11-12T12:00:10Z"}
    JSONL

    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test tool use parity",
      status: :archived,
      agent_runtime: "claude_code",
      branch: "main",
      transcript: jsonl_transcript,
      metadata: { "broadcast_message_count" => 3 }
    )

    # Visit the session page with condensed filter to see tool messages
    # (default "minimal" filter hides tool-use/result messages)
    visit session_path(session, filter: "condensed")
    assert_selector "[data-controller='transcript-copy'] button[aria-label='Copy full transcript to clipboard']"

    # Extract timeline HTML
    timeline_html_initial = extract_normalized_timeline_html

    # Verify tool use content is present
    assert timeline_html_initial.include?("Read"), "Should show tool name"
    assert timeline_html_initial.include?("Tool Result") || timeline_html_initial.include?("Tool Use"),
           "Should show tool use/result indicators"

    # Refresh the page (with same filter)
    visit session_path(session, filter: "condensed")
    assert_selector "[data-controller='transcript-copy'] button[aria-label='Copy full transcript to clipboard']"

    # Extract timeline HTML again
    timeline_html_after_refresh = extract_normalized_timeline_html

    # Should be identical
    assert_equal timeline_html_initial, timeline_html_after_refresh,
                 "Timeline with tool use should be identical before and after refresh"
  end

  test "timeline with Claude Code events renders consistently on refresh" do
    # Create a session with Claude Code specific events
    jsonl_transcript = <<~JSONL.strip
      {"type":"queue-operation","operation":"start","content":"Session started","timestamp":"2025-11-12T12:00:00Z"}
      {"type":"system","subtype":"git_status","content":"On branch main","timestamp":"2025-11-12T12:00:05Z"}
      {"type":"user","message":{"role":"user","content":"Check git status"},"timestamp":"2025-11-12T12:00:10Z"}
    JSONL

    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test Claude Code events parity",
      status: :archived,
      agent_runtime: "claude_code",
      branch: "main",
      transcript: jsonl_transcript,
      metadata: { "broadcast_message_count" => 3 }
    )

    # Visit the session page with verbose filter. Under OpenTranscripts, a
    # queue-operation normalizes to a "queue-event" (hidden at minimal) and a
    # plain system line normalizes to a SystemEvent in the "regular-log"
    # category (hidden until show-logs/verbose), so verbose exercises both
    # through the single render path.
    visit session_path(session, filter: "verbose")
    assert_selector "[data-controller='transcript-copy'] button[aria-label='Copy full transcript to clipboard']"

    # Extract timeline HTML
    timeline_html_initial = extract_normalized_timeline_html

    # Verify Claude Code events are present
    assert timeline_html_initial.include?("Queue Event") || timeline_html_initial.include?("queue-operation"),
           "Should show queue event"
    assert timeline_html_initial.include?("System"), "Should show system event"

    # Refresh the page
    visit session_path(session, filter: "verbose")
    assert_selector "[data-controller='transcript-copy'] button[aria-label='Copy full transcript to clipboard']"

    # Extract timeline HTML again
    timeline_html_after_refresh = extract_normalized_timeline_html

    # Should be identical
    assert_equal timeline_html_initial, timeline_html_after_refresh,
                 "Timeline with Claude Code events should be identical before and after refresh"
  end

  private

  def extract_normalized_timeline_html
    # Get the timeline container HTML
    timeline_element = find("#session_#{Session.last.id}_timeline")
    html = timeline_element["innerHTML"]

    # Normalize the HTML by removing dynamic timestamp text
    # The timestamp text updates but the structure should be identical
    # Replace "X minutes ago" with "NORMALIZED" to make comparison work
    normalized = html.gsub(/(\d+|less than a|about|almost|over) (second|minute|hour|day)s? ago/, "TIMESTAMP_NORMALIZED")

    # Also normalize any data-timestamp ISO8601 values that might differ slightly
    normalized = normalized.gsub(/data-timestamp="[^"]*"/, 'data-timestamp="NORMALIZED"')

    # Normalize whitespace for comparison
    normalized.gsub(/\s+/, " ").strip
  end
end
