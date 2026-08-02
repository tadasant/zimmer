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

  test "author must be a configured human identity" do
    message = build_message(author: "some-agent")

    refute message.valid?
    assert_includes message.errors[:author], "must be a configured human identity"
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

  test "display_name resolves through the identity config" do
    assert_equal "Tadas", build_message(author: "tadasant").display_name
    assert_equal "Julie", build_message(author: "juliehazz").display_name
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
end
