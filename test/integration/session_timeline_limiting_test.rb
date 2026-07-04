require "test_helper"

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

  test "show page renders limited timeline items for session with many messages" do
    session = create_session_with_many_messages(count: 150)

    get session_path(session)
    assert_response :success

    # Count data-timeline-item in the response body
    timeline_items_count = response.body.scan(/data-timeline-item/).count

    # Should have limited items (100 is the limit, but we allow some slack)
    assert timeline_items_count <= 110, "Should have limited items, got #{timeline_items_count}"
    assert timeline_items_count >= 90, "Should have at least 90 items, got #{timeline_items_count}"
  end

  test "show page shows infinite scroll trigger when more items available" do
    session = create_session_with_many_messages(count: 150)

    get session_path(session)
    assert_response :success

    # Should have the "Load more" button since there are more items
    assert_includes response.body, "Load earlier messages"
  end

  test "show page does not show infinite scroll trigger for small sessions" do
    session = create_session_with_many_messages(count: 50)

    get session_path(session)
    assert_response :success

    # Should NOT have the "Load more" button since all items fit
    assert_not_includes response.body, "Load earlier messages"
  end
end
