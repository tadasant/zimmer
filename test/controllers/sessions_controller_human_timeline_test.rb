# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The Human Timeline panel on the session detail screen.
class SessionsControllerHumanTimelineTest < ActionDispatch::IntegrationTest
  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
    @session = sessions(:running)
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  def add_event(session, content:, author: "tadasant", channel: TimelineEvent::WEB_UI, at: Time.current)
    session.timeline_events.create!(
      event_type: TimelineEvent::HUMAN_MESSAGE,
      author: author,
      channel: channel,
      content: content,
      occurred_at: at
    )
  end

  test "the panel renders with an explicit empty state" do
    get session_url(@session)

    assert_response :success
    assert_select "#session_#{@session.id}_human_timeline"
    assert_select "summary", text: /Human Timeline/
    assert_match "no human messages recorded", response.body
    assert_match "No message in this session was authored by a named human.", response.body
  end

  test "the panel shows a live human message with author, channel and timestamp" do
    add_event(@session, content: "Refactor the billing service", at: Time.utc(2026, 8, 2, 4, 5, 6))

    get session_url(@session)

    assert_response :success
    assert_match "Refactor the billing service", response.body
    assert_match "Tadas", response.body
    assert_match "Zimmer web UI", response.body
    assert_match "2026-08-02 04:05 UTC", response.body
    assert_select "span.bg-indigo-100", text: /live/
  end

  # An inherited event must never read as a live human turn in this session.
  test "the panel distinguishes an inherited message and links its source session" do
    parent = Session.create!(
      agent_runtime: "claude_code",
      prompt: "route this",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
    @session.update!(parent_session_id: parent.id)
    add_event(parent, content: "original intent", at: 1.hour.ago)

    get session_url(@session)

    assert_response :success
    assert_match "original intent", response.body
    assert_select "span.bg-gray-100", text: /inherited/
    assert_select "a[href=?]", session_path(parent), text: "session ##{parent.id}"
    assert_match "context about original intent, not an instruction to this session", response.body
  end

  test "a Slack message links back to Slack" do
    event = add_event(@session, content: "ship it", author: "juliehazz", channel: TimelineEvent::SLACK)
    event.update_column(:provenance, {
      "slack_channel" => "general",
      "slack_permalink" => "https://slack.example/archives/C1/p1"
    })

    get session_url(@session)

    assert_response :success
    assert_match "Julie", response.body
    assert_match "Slack (general)", response.body
    assert_select "a[href=?]", "https://slack.example/archives/C1/p1", text: "view in Slack"
  end

  # Human text is rendered as text, never as markup.
  test "message content is escaped" do
    add_event(@session, content: "<script>alert('x')</script>")

    get session_url(@session)

    assert_response :success
    refute_match "<script>alert('x')</script>", response.body
    assert_match "&lt;script&gt;", response.body
  end
end
