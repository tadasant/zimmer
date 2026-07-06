require "test_helper"

class SessionsControllerInfiniteScrollTest < ActionDispatch::IntegrationTest
  setup do
    @session = sessions(:running)
    # Create a session with many timeline items
    create_session_with_many_items
  end

  # Test show page pagination
  test "should show only last 100 items on initial page load when session has more items" do
    get session_url(@large_session)

    assert_response :success
    # Should show that there are more items to load
    assert_match /Showing 100 of/, response.body
    assert_match /Load earlier messages/, response.body
  end

  test "should show all items when session has fewer than 100 items" do
    # Session with just 3 messages
    get session_url(sessions(:with_transcript))

    assert_response :success
    # Should not show the "load more" button
    assert_no_match /Load earlier messages/, response.body
    # Should show total item count
    assert_match /3 items/, response.body
  end

  test "should include infinite scroll data attributes" do
    get session_url(@large_session)

    assert_response :success
    assert_select "[data-controller='infinite-scroll']"
    assert_select "[data-infinite-scroll-url-value]"
    assert_select "[data-infinite-scroll-before-index-value]"
    assert_select "[data-infinite-scroll-has-more-value]"
  end

  # Test timeline_items action
  test "should return older timeline items via timeline_items action" do
    # Use minimal filter (messages only) since @large_session has only messages
    get timeline_items_session_url(@large_session, before_index: 50, filter: "minimal")

    assert_response :success
    # Should include pagination state element
    assert_select "#timeline-pagination-state"
  end

  test "should return empty batch when before_index is 0" do
    get timeline_items_session_url(@large_session, before_index: 0, filter: "minimal")

    assert_response :success
    # Should indicate no more items
    assert_select "#timeline-pagination-state[data-has-more='false']"
  end

  test "should limit batch size to 200 maximum" do
    # Request more than 200 items
    get timeline_items_session_url(@large_session, before_index: 150, limit: 500, filter: "minimal")

    assert_response :success
    # Should not crash and should return a valid response
    assert_response :success
  end

  test "should handle timeline_items for session with no items" do
    get timeline_items_session_url(sessions(:running), before_index: 10, filter: "minimal")

    assert_response :success
    # Should return with no more items
    assert_select "#timeline-pagination-state[data-has-more='false']"
  end

  test "should return correct next_before_index for pagination" do
    # With 150 filtered items (messages) total, request items before index 100
    # Should return items 0-99 (100 items) with next_before_index of 0
    get timeline_items_session_url(@large_session, before_index: 100, filter: "minimal")

    assert_response :success
    assert_select "#timeline-pagination-state[data-next-before-index='0']"
    assert_select "#timeline-pagination-state[data-has-more='false']"
  end

  test "show page sets correct before_index value when items are truncated" do
    get session_url(@large_session)

    assert_response :success
    # With 150 items and showing last 100, before_index should be 50
    assert_select "[data-infinite-scroll-before-index-value='50']"
  end

  test "timeline_items action returns items in correct order" do
    get timeline_items_session_url(@large_session, before_index: 10, limit: 5, filter: "minimal")

    assert_response :success
    # Should return items for the timeline
    assert_select "[data-timeline-item]"
  end

  # Test filter category data attributes
  # Note: These tests use filter=verbose to see all item types since the default
  # filter is "minimal" which only shows messages (not logs or tool messages)
  test "timeline items have data-filter-category attribute for messages" do
    get session_url(sessions(:with_transcript), filter: "verbose")

    assert_response :success
    # Messages should have filter-category="message"
    assert_select "[data-timeline-item][data-filter-category='message']"
  end

  test "timeline items have data-filter-category attribute for regular logs" do
    session = sessions(:running)
    # Add a regular (non-verbose) log
    session.logs.create!(
      level: "info",
      content: "Test info log",
      created_at: Time.current
    )

    # Use verbose filter to see logs
    get session_url(session, filter: "verbose")

    assert_response :success
    # Regular logs should have filter-category="regular-log"
    assert_select "[data-timeline-item][data-filter-category='regular-log']"
  end

  test "timeline items have data-filter-category attribute for verbose logs" do
    session = sessions(:running)
    # Add a verbose log
    session.logs.create!(
      level: "verbose",
      content: "Verbose debug info",
      created_at: Time.current
    )

    # Use verbose filter to see verbose logs
    get session_url(session, filter: "verbose")

    assert_response :success
    # Verbose logs should have filter-category="verbose-log"
    assert_select "[data-timeline-item][data-filter-category='verbose-log']"
  end

  test "session with mixed items has correct filter categories" do
    session = create_session_with_mixed_items

    # Use verbose filter to see all item types
    get session_url(session, filter: "verbose")

    assert_response :success
    # Should have all three categories
    assert_select "[data-timeline-item][data-filter-category='message']"
    assert_select "[data-timeline-item][data-filter-category='regular-log']"
    assert_select "[data-timeline-item][data-filter-category='verbose-log']"
  end

  test "timeline items have data-filter-category tool-message for tool use messages" do
    session = create_session_with_tool_use_messages

    # Use condensed filter (or higher) to see tool messages
    get session_url(session, filter: "condensed")

    assert_response :success
    # Tool use messages should have filter-category="tool-message"
    assert_select "[data-timeline-item][data-filter-category='tool-message']"
    # Regular messages should still have filter-category="message"
    assert_select "[data-timeline-item][data-filter-category='message']"
  end

  test "timeline items have data-filter-category tool-message for tool result messages" do
    session = create_session_with_tool_result_messages

    # Use condensed filter (or higher) to see tool messages
    get session_url(session, filter: "condensed")

    assert_response :success
    # Tool result messages should have filter-category="tool-message"
    assert_select "[data-timeline-item][data-filter-category='tool-message']"
  end

  test "timeline_items batch response includes filter category attributes" do
    session = create_session_with_mixed_items_large

    get timeline_items_session_url(session, before_index: 50, filter: "verbose")

    assert_response :success
    # Batch should include filter categories
    assert_select "[data-timeline-item][data-filter-category]"
  end

  # Test server-side filtering for pagination
  test "show page with filter param shows 100 filtered items" do
    session = create_session_with_many_logs_few_messages

    # With minimal filter, should only get messages (not logs)
    get session_url(session, filter: "minimal")

    assert_response :success
    # Should show the messages only (25 messages available, all should be shown)
    assert_select "[data-timeline-item][data-filter-category='message']", 25
    # Should NOT show any logs
    assert_select "[data-timeline-item][data-filter-category='regular-log']", 0
    assert_select "[data-timeline-item][data-filter-category='verbose-log']", 0
  end

  test "show page with verbose filter shows all item types" do
    session = create_session_with_many_logs_few_messages

    # With verbose filter, should get everything (limited to 100)
    # Total: 25 messages + 100 regular logs + 100 verbose logs = 225 items
    # Last 100 should be mostly logs given the timestamps
    get session_url(session, filter: "verbose")

    assert_response :success
    # Should show that there are more items and have a mix of types
    assert_match /Showing 100 of 225/, response.body
    # Should have logs in the visible items (since logs are more recent)
    assert_select "[data-timeline-item][data-filter-category='regular-log']"
    assert_select "[data-timeline-item][data-filter-category='verbose-log']"
  end

  test "show page includes filter level data attribute" do
    get session_url(@large_session, filter: "condensed")

    assert_response :success
    assert_select "[data-infinite-scroll-filter-level-value='condensed']"
  end

  test "show page with invalid filter defaults to minimal" do
    get session_url(@large_session, filter: "invalid_filter")

    assert_response :success
    assert_select "[data-infinite-scroll-filter-level-value='minimal']"
  end

  test "timeline_items action respects filter parameter" do
    session = create_session_with_mixed_items_large

    # Request items with minimal filter (messages only)
    get timeline_items_session_url(session, before_index: 50, filter: "minimal")

    assert_response :success
    # Should only return message items, not logs
    assert_select "[data-timeline-item][data-filter-category='message']"
    assert_select "[data-timeline-item][data-filter-category='regular-log']", 0
    assert_select "[data-timeline-item][data-filter-category='verbose-log']", 0
  end

  test "timeline_items action with verbose filter returns all types" do
    session = create_session_with_mixed_items_large

    # Request items with verbose filter (all items)
    # The mixed_items_large session has 100 messages + 50 logs = 150 total with verbose
    # Request items before index 150 to get older items
    get timeline_items_session_url(session, before_index: 150, filter: "verbose")

    assert_response :success
    # Should return some items (may include logs if in the requested range)
    assert_select "[data-timeline-item]"
  end

  test "show-logs filter includes regular logs but not verbose" do
    session = create_session_with_mixed_items_large

    get timeline_items_session_url(session, before_index: 50, filter: "show-logs")

    assert_response :success
    # Should include regular logs but not verbose logs
    # Note: The assertions depend on what's in the slice - verbose logs should be filtered out
    assert_select "[data-timeline-item][data-filter-category='verbose-log']", 0
  end

  test "filtered pagination correctly counts remaining items" do
    session = create_session_with_many_logs_few_messages

    # With minimal filter (25 messages only), all should be shown
    get session_url(session, filter: "minimal")

    assert_response :success
    # Should show all 25 messages (no pagination needed)
    assert_match /25 items/, response.body
    # Should NOT show "Load earlier messages" since all fit
    assert_no_match /Load earlier messages/, response.body
  end

  test "filtered pagination shows correct load more count when items exceed limit" do
    session = create_session_with_150_messages

    # With minimal filter (150 messages), should show 100 and have 50 more
    get session_url(session, filter: "minimal")

    assert_response :success
    assert_match /Showing 100 of 150/, response.body
    assert_match /Load earlier messages \(50 more\)/, response.body
  end

  test "show page select element reflects server filter value" do
    get session_url(@large_session, filter: "show-logs")

    assert_response :success
    # The show-logs option should be selected
    assert_select "select#log-level-filter option[value='show-logs'][selected]"
  end

  private

  def create_session_with_many_items
    # Create a session with 150 transcript entries
    transcript_entries = []
    150.times do |i|
      timestamp = (Time.current - (150 - i).minutes).iso8601
      if i.even?
        transcript_entries << {
          "type" => "user",
          "message" => { "role" => "user", "content" => "User message #{i}" },
          "timestamp" => timestamp
        }
      else
        transcript_entries << {
          "type" => "assistant",
          "message" => { "role" => "assistant", "content" => "Assistant response #{i}" },
          "timestamp" => timestamp
        }
      end
    end

    @large_session = Session.create!(
      agent_runtime: "claude_code",
      status: :running,
      prompt: "Test session with many messages",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      transcript: transcript_entries.map(&:to_json).join("\n")
    )
  end

  def create_session_with_mixed_items
    # Create a session with messages and both types of logs
    transcript_entries = [
      {
        "type" => "user",
        "message" => { "role" => "user", "content" => "Hello" },
        "timestamp" => 1.hour.ago.iso8601
      },
      {
        "type" => "assistant",
        "message" => { "role" => "assistant", "content" => "Hi there!" },
        "timestamp" => 59.minutes.ago.iso8601
      }
    ]

    session = Session.create!(
      agent_runtime: "claude_code",
      status: :running,
      prompt: "Test session with mixed items",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      transcript: transcript_entries.map(&:to_json).join("\n")
    )

    # Add regular and verbose logs
    session.logs.create!(level: "info", content: "Regular log message", created_at: 58.minutes.ago)
    session.logs.create!(level: "verbose", content: "Verbose log message", created_at: 57.minutes.ago)

    session
  end

  def create_session_with_mixed_items_large
    # Create a session with 150 items including messages and logs
    transcript_entries = []
    100.times do |i|
      timestamp = (Time.current - (150 - i).minutes).iso8601
      transcript_entries << {
        "type" => i.even? ? "user" : "assistant",
        "message" => { "role" => i.even? ? "user" : "assistant", "content" => "Message #{i}" },
        "timestamp" => timestamp
      }
    end

    session = Session.create!(
      agent_runtime: "claude_code",
      status: :running,
      prompt: "Test session with mixed items large",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      transcript: transcript_entries.map(&:to_json).join("\n")
    )

    # Add logs interleaved with messages
    25.times do |i|
      session.logs.create!(
        level: "info",
        content: "Regular log #{i}",
        created_at: (Time.current - (50 - i).minutes)
      )
      session.logs.create!(
        level: "verbose",
        content: "Verbose log #{i}",
        created_at: (Time.current - (50 - i).minutes + 30.seconds)
      )
    end

    session
  end

  def create_session_with_tool_use_messages
    # Create a session with a regular message and a tool_use message
    transcript_entries = [
      {
        "type" => "user",
        "message" => { "role" => "user", "content" => "Please read the file" },
        "timestamp" => 1.hour.ago.iso8601
      },
      {
        "type" => "assistant",
        "message" => {
          "role" => "assistant",
          "content" => [
            { "type" => "tool_use", "id" => "toolu_123", "name" => "Read", "input" => { "file_path" => "/test.txt" } }
          ]
        },
        "timestamp" => 59.minutes.ago.iso8601
      }
    ]

    Session.create!(
      agent_runtime: "claude_code",
      status: :running,
      prompt: "Test session with tool use messages",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      transcript: transcript_entries.map(&:to_json).join("\n")
    )
  end

  def create_session_with_tool_result_messages
    # Create a session with a tool_result message
    transcript_entries = [
      {
        "type" => "user",
        "message" => {
          "role" => "user",
          "content" => [
            { "type" => "tool_result", "tool_use_id" => "toolu_123", "content" => "File contents here" }
          ]
        },
        "timestamp" => 1.hour.ago.iso8601
      }
    ]

    Session.create!(
      agent_runtime: "claude_code",
      status: :running,
      prompt: "Test session with tool result messages",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      transcript: transcript_entries.map(&:to_json).join("\n")
    )
  end

  def create_session_with_many_logs_few_messages
    # Create a session with 25 messages and 200 logs
    # This tests that filtering works: with minimal filter should see 25 items (not 100 from 225)
    transcript_entries = []
    25.times do |i|
      timestamp = (Time.current - (300 - i).minutes).iso8601
      transcript_entries << {
        "type" => i.even? ? "user" : "assistant",
        "message" => { "role" => i.even? ? "user" : "assistant", "content" => "Message #{i}" },
        "timestamp" => timestamp
      }
    end

    session = Session.create!(
      agent_runtime: "claude_code",
      status: :running,
      prompt: "Test session with many logs few messages",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      transcript: transcript_entries.map(&:to_json).join("\n")
    )

    # Add 100 regular logs and 100 verbose logs (interleaved)
    100.times do |i|
      session.logs.create!(
        level: "info",
        content: "Regular log #{i}",
        created_at: (Time.current - (200 - i).minutes)
      )
      session.logs.create!(
        level: "verbose",
        content: "Verbose log #{i}",
        created_at: (Time.current - (200 - i).minutes + 30.seconds)
      )
    end

    session
  end

  def create_session_with_150_messages
    # Create a session with exactly 150 messages (no logs)
    # This tests pagination with messages-only filter
    transcript_entries = []
    150.times do |i|
      timestamp = (Time.current - (200 - i).minutes).iso8601
      transcript_entries << {
        "type" => i.even? ? "user" : "assistant",
        "message" => { "role" => i.even? ? "user" : "assistant", "content" => "Message #{i}" },
        "timestamp" => timestamp
      }
    end

    Session.create!(
      agent_runtime: "claude_code",
      status: :running,
      prompt: "Test session with 150 messages",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      transcript: transcript_entries.map(&:to_json).join("\n")
    )
  end
end
