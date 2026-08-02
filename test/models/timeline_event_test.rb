# frozen_string_literal: true

require "test_helper"

class TimelineEventTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
  end

  def build_event(**overrides)
    @session.timeline_events.new({
      event_type: TimelineEvent::HUMAN_MESSAGE,
      author: "tadasant",
      channel: TimelineEvent::WEB_UI,
      content: "ship it",
      occurred_at: Time.current
    }.merge(overrides))
  end

  test "a well-formed human message is valid" do
    assert build_event.valid?
  end

  test "author must be a configured human identity" do
    event = build_event(author: "some-agent")

    refute event.valid?
    assert_includes event.errors[:author], "must be a configured human identity"
  end

  test "author cannot be blank" do
    refute build_event(author: nil).valid?
    refute build_event(author: "").valid?
  end

  test "channel is restricted to the known provenance channels" do
    refute build_event(channel: "github").valid?
    assert build_event(channel: TimelineEvent::SLACK).valid?
  end

  test "event_type is restricted to the known types" do
    refute build_event(event_type: "agent_message").valid?
  end

  test "content and occurred_at are required" do
    refute build_event(content: "").valid?
    refute build_event(occurred_at: nil).valid?
  end

  # The append-only guarantee is the whole point: a timeline that can be edited
  # after the fact to say a human asked for something is worth nothing.
  test "an event cannot be updated once written" do
    event = build_event
    event.save!

    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(content: "actually, don't ship it") }
    assert_equal "ship it", event.reload.content
  end

  test "an event cannot be destroyed directly" do
    event = build_event
    event.save!

    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy! }
    assert TimelineEvent.exists?(event.id)
  end

  # …but it must not outlive its session, or deleting a session would fail.
  test "an event is removed with its session" do
    session = Session.create!(
      agent_runtime: "claude_code",
      prompt: "temp",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
    event = session.timeline_events.create!(
      event_type: TimelineEvent::HUMAN_MESSAGE,
      author: "tadasant",
      channel: TimelineEvent::WEB_UI,
      content: "hello",
      occurred_at: Time.current
    )

    session.destroy!

    refute TimelineEvent.exists?(event.id)
  end

  test "display_name resolves through the identity config" do
    assert_equal "Tadas", build_event(author: "tadasant").display_name
    assert_equal "Julie", build_event(author: "juliehazz").display_name
  end

  test "provenance accessors read the stored hash" do
    event = build_event(
      channel: TimelineEvent::SLACK,
      provenance: {
        "entry_point" => "slack.channel_message",
        "slack_channel" => "general",
        "slack_permalink" => "https://slack.example/p1"
      }
    )

    assert_equal "slack.channel_message", event.entry_point
    assert_equal "general", event.slack_channel_name
    assert_equal "https://slack.example/p1", event.slack_permalink
  end

  test "chronological orders by occurred_at then id" do
    base = Time.current
    later = build_event(content: "second", occurred_at: base + 1.minute)
    later.save!
    earlier = build_event(content: "first", occurred_at: base)
    earlier.save!

    assert_equal %w[first second], @session.timeline_events.chronological.map(&:content)
  end
end
