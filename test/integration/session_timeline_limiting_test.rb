require "test_helper"

# How much of a long session's timeline the first render carries.
#
# Asserted against #transcript_panel, which is where the detail page defers the
# timeline to — the page itself renders none of it until the reader opens the
# Transcript disclosure.
class SessionTimelineLimitingTest < ActionDispatch::IntegrationTest
  def create_session_with_many_messages(count:)
    transcript_entries = count.times.map do |i|
      role = i.even? ? "user" : "assistant"
      timestamp = (Time.now.utc - (count - i).minutes).iso8601
      {
        type: role,
        message: { role: role, content: "Message #{i + 1} - This is a #{role} message" },
        timestamp: timestamp
      }.to_json
    end.join("\n")

    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test session with #{count} messages",
      status: :running,
      agent_runtime: "claude_code",
      branch: "main",
      transcript: transcript_entries
    )
  end

  test "transcript panel renders limited timeline items for session with many messages" do
    session = create_session_with_many_messages(count: 150)

    get transcript_panel_session_path(session)
    assert_response :success

    # Count data-timeline-item in the response body
    timeline_items_count = response.body.scan(/data-timeline-item/).count

    # Tail first: the panel's own response is only the newest few items.
    assert_equal SessionsController::TRANSCRIPT_TAIL_LIMIT, timeline_items_count
  end

  test "transcript panel shows infinite scroll trigger when more items available" do
    session = create_session_with_many_messages(count: 150)

    get transcript_panel_session_path(session)
    assert_response :success

    # Should have the "Load more" button since there are more items
    assert_includes response.body, "Load earlier messages"
  end

  test "transcript panel does not show infinite scroll trigger for small sessions" do
    session = create_session_with_many_messages(count: SessionsController::TRANSCRIPT_TAIL_LIMIT)

    get transcript_panel_session_path(session)
    assert_response :success

    # Should NOT have the "Load more" button since all items fit
    assert_not_includes response.body, "Load earlier messages"
  end
end
