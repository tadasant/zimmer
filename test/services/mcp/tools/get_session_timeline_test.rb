# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The Human Timeline section of get_session.
#
# Deliberately not behind an `include_` flag: the most important reading of a
# timeline is the EMPTY one, and a caller asking "did a human authorize this?"
# must not confuse "no human turns" with "I forgot the flag".
class Mcp::Tools::GetSessionTimelineTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::GetSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
    @session = sessions(:running)
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

  test "an empty timeline says so explicitly rather than being omitted" do
    output = @tool.call("id" => @session.id)

    assert_includes output, "### Human Timeline"
    assert_includes output, "- **Live human messages to this session:** 0"
    assert_includes output, "_No message in this session was authored by a named human._"
  end

  test "a populated timeline shows author, channel, timestamp and content" do
    add_event(@session, content: "Refactor the billing service", at: Time.utc(2026, 8, 2, 4, 5, 6))

    output = @tool.call("id" => @session.id)

    assert_includes output, "### Human Timeline"
    assert_includes output, "- **Live human messages to this session:** 1"
    assert_includes output, "**[live]** Tadas (`tadasant`) via Zimmer web UI at 2026-08-02T04:05:06Z"
    assert_includes output, "Refactor the billing service"

    # Printed so the real tool output for a populated timeline is visible in CI,
    # rather than only the fact that some substrings matched.
    section = output[/### Human Timeline.*?(?=\n### )/m] || output[/### Human Timeline.*/m]
    puts "\n--- get_session HUMAN TIMELINE SECTION ---\n#{section}\n--- END SECTION ---\n"
  end

  test "an inherited entry names its source session and is not labelled live" do
    parent = Session.create!(
      agent_runtime: "claude_code",
      prompt: "route this",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
    @session.update!(parent_session_id: parent.id)
    add_event(parent, content: "original intent", at: 1.hour.ago)

    output = @tool.call("id" => @session.id)

    assert_includes output, "**[inherited]**"
    assert_includes output, "(from session ##{parent.id})"
    assert_includes output, "- **Live human messages to this session:** 0"
    assert_includes output, "- **Inherited from ancestor sessions:** 1"
    refute_includes output, "**[live]**"
  end

  test "the section explains that an absent turn is machine-authored" do
    output = @tool.call("id" => @session.id)

    assert_includes output, "was machine-authored"
    assert_includes output, "not evidence of human authorization"
  end

  test "the section is bounded and reports what it omitted" do
    40.times { |i| add_event(@session, content: "msg #{i}", at: i.minutes.from_now) }

    output = @tool.call("id" => @session.id)

    assert_includes output, "msg 39"
    assert_includes output, "_15 older entries omitted._"
  end

  test "a Slack entry names the Slack channel" do
    event = add_event(@session, content: "ship it", author: "juliehazz", channel: TimelineEvent::SLACK)
    event.update_column(:provenance, { "slack_channel" => "general" })

    output = @tool.call("id" => @session.id)

    assert_includes output, "Julie (`juliehazz`) via Slack (general)"
  end
end

# Parity: POST /api/v1/sessions has always permitted parent_session_id; the
# start_session tool did not, so an agent could not create the spawn edge the
# Human Timeline walks.
class Mcp::Tools::StartSessionParentTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::StartSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
    AgentSessionJob.stubs(:enqueue_new_session).returns(stub(job_id: "job-1"))
  end

  teardown { Mocha::Mockery.instance.teardown }

  test "start_session records the spawn edge so the child inherits human context" do
    parent = sessions(:running)
    parent.timeline_events.create!(
      event_type: TimelineEvent::HUMAN_MESSAGE,
      author: "tadasant",
      channel: TimelineEvent::WEB_UI,
      content: "the original ask",
      occurred_at: 1.hour.ago
    )

    @tool.call("agent_root" => "zimmer", "prompt" => "downstream work", "parent_session_id" => parent.id)

    child = Session.order(:id).last
    assert_equal parent.id, child.parent_session_id
    assert_equal [ "the original ask" ], child.timeline.entries.map(&:content)
    assert child.timeline.entries.all?(&:inherited?)
    refute child.timeline.live_human_message?
  end

  test "parent_session_id is advertised in the tool schema" do
    assert_includes Mcp::Tools::StartSession.input_schema.to_h[:properties].keys.map(&:to_s), "parent_session_id"
  end
end
