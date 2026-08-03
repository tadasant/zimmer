# frozen_string_literal: true

require "test_helper"

class HumanMessageTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
  end

  def build_message(**overrides)
    @session.human_messages.new({
      author: "tadasant",
      channel: HumanMessage::WEB_UI,
      content: "ship it",
      occurred_at: Time.current
    }.merge(overrides))
  end

  test "a well-formed human message is valid" do
    assert build_message.valid?
  end

  test "author must be a seeded user" do
    message = build_message(author: "some-agent")

    refute message.valid?
    assert_includes message.errors[:author], "must be a seeded user"
  end

  test "author cannot be blank" do
    refute build_message(author: nil).valid?
    refute build_message(author: "").valid?
  end

  test "channel is restricted to the known provenance channels" do
    refute build_message(channel: "github").valid?
    assert build_message(channel: HumanMessage::SLACK).valid?
  end

  test "content and occurred_at are required" do
    refute build_message(content: "").valid?
    refute build_message(occurred_at: nil).valid?
  end

  # Read-only is the whole point: a record that can be edited after the fact to
  # say a human asked for something is worth nothing.
  test "a record cannot be updated once written" do
    message = build_message
    message.save!

    assert_raises(ActiveRecord::ReadOnlyRecord) { message.update!(content: "actually, don't ship it") }
    assert_equal "ship it", message.reload.content
  end

  test "a record cannot be destroyed directly" do
    message = build_message
    message.save!

    assert_raises(ActiveRecord::ReadOnlyRecord) { message.destroy! }
    assert HumanMessage.exists?(message.id)
  end

  # …but it must not outlive its session, or deleting a session would fail.
  test "a record is removed with its session" do
    session = Session.create!(
      agent_runtime: "claude_code",
      prompt: "temp",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
    message = session.human_messages.create!(
      author: "tadasant",
      channel: HumanMessage::WEB_UI,
      content: "hello",
      occurred_at: Time.current
    )

    session.destroy!

    refute HumanMessage.exists?(message.id)
  end

  test "display_name resolves through the users table" do
    assert_equal "Tadas", build_message(author: "tadasant").display_name
    assert_equal "Julie", build_message(author: "juliehazz").display_name
  end

  # `author` is a key, not a foreign key, precisely so an immutable record
  # survives the roster changing under it.
  test "a record whose author left the roster still renders, naming the key" do
    message = @session.human_messages.create!(
      author: "juliehazz",
      channel: HumanMessage::SLACK,
      content: "the rest should all be actioned",
      occurred_at: Time.current
    )

    users(:juliehazz).destroy!

    message.reload
    assert_equal "juliehazz", message.author
    assert_nil message.user
    assert_equal "juliehazz", message.display_name
    assert_nil message.author_notes
  end

  test "author_notes carries the roster's context about the human" do
    assert_equal users(:tadasant).notes, build_message(author: "tadasant").author_notes
    assert_nil build_message(author: "juliehazz").author_notes
  end

  test "channel_label names the channel a reader has to weigh" do
    assert_equal "Zimmer web UI", build_message.channel_label
    assert_equal "Slack", build_message(channel: HumanMessage::SLACK).channel_label
    assert_equal "Slack (general)", build_message(
      channel: HumanMessage::SLACK, provenance: { "slack_channel" => "general" }
    ).channel_label
  end

  test "provenance accessors read the stored hash" do
    message = build_message(
      channel: HumanMessage::SLACK,
      provenance: {
        "entry_point" => "slack.channel_message",
        "slack_channel" => "general",
        "slack_permalink" => "https://slack.example/p1"
      }
    )

    assert_equal "slack.channel_message", message.entry_point
    assert_equal "general", message.slack_channel_name
    assert_equal "https://slack.example/p1", message.slack_permalink
  end

  test "chronological orders by occurred_at then id" do
    base = Time.current
    build_message(content: "second", occurred_at: base + 1.minute).save!
    build_message(content: "first", occurred_at: base).save!

    assert_equal %w[first second], @session.human_messages.chronological.map(&:content)
  end

  test "creating a record refreshes provenance panels across the hierarchy" do
    parent = Session.create!(
      agent_runtime: "claude_code",
      prompt: "parent",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: "Parent"
    )
    child = Session.create!(
      agent_runtime: "claude_code",
      prompt: "child",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: "Child",
      parent_session_id: parent.id
    )

    broadcasts = []
    Turbo::StreamsChannel.stubs(:broadcast_replace_to).with do |stream, **options|
      broadcasts << [ stream, options ]
      true
    end

    child.human_messages.create!(
      author: "tadasant",
      channel: HumanMessage::WEB_UI,
      content: "human context for the child",
      occurred_at: Time.current
    )

    parent_broadcast = broadcasts.find do |stream, options|
      stream == "session_#{parent.id}_status" &&
        options[:target] == "session_#{parent.id}_provenance"
    end

    assert parent_broadcast, "Expected parent provenance panel to refresh when a child records a human message"
    assert_includes parent_broadcast.last[:html], "human context for the child"
    assert_includes parent_broadcast.last[:html], "elsewhere"
  end
end
