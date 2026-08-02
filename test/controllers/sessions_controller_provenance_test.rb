# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The session hierarchy and human-message panels on the session detail screen.
class SessionsControllerProvenanceTest < ActionDispatch::IntegrationTest
  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
    @session = sessions(:running)
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  def spawn_session(parent: nil, title: nil, agent_root: nil)
    session = Session.create!(
      agent_runtime: "claude_code",
      prompt: "work",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: title,
      parent_session_id: parent&.id
    )
    session.update!(metadata: (session.metadata || {}).merge("agent_root_key" => agent_root)) if agent_root
    session
  end

  def add_message(session, content:, author: "tadasant", channel: HumanMessage::WEB_UI, at: Time.current)
    session.human_messages.create!(
      author: author,
      channel: channel,
      content: content,
      occurred_at: at
    )
  end

  test "the panels render with explicit empty states" do
    get session_url(@session)

    assert_response :success
    assert_select "#session_#{@session.id}_provenance"
    assert_select "summary", text: /Session hierarchy/
    assert_select "summary", text: /Human messages/
    assert_match "this session was not spawned by another and has spawned none", response.body
    assert_match "No message anywhere in this hierarchy was authored by a named human.", response.body
  end

  # The hierarchy view is an explicit requirement: nodes with title + agent root,
  # each clickable, the current session marked.
  test "the hierarchy renders clickable nodes with title and agent root" do
    router = spawn_session(title: "Route it", agent_root: "zimmer-router")
    worker = spawn_session(parent: router, title: "Do it", agent_root: "zimmer")
    helper = spawn_session(parent: worker, title: "Help out", agent_root: "artifacts")

    get session_url(worker)

    assert_response :success
    # Every other node in the tree links through to its own detail page.
    assert_select "a[href=?]", session_path(router), text: "Route it"
    assert_select "a[href=?]", session_path(helper), text: "Help out"
    # The current session is marked and is NOT a link to itself.
    assert_match "this session", response.body
    assert_select "a[href=?]", session_path(worker), false
    # Agent roots are shown on the nodes.
    assert_match "zimmer-router", response.body
    assert_match "artifacts", response.body
  end

  test "a descendant appears in an ancestor's hierarchy view" do
    router = spawn_session(title: "Route it", agent_root: "zimmer-router")
    worker = spawn_session(parent: router, title: "Do it", agent_root: "zimmer")

    get session_url(router)

    assert_response :success
    assert_select "a[href=?]", session_path(worker), text: "Do it"
  end

  test "a human message said to this session shows author, channel and timestamp" do
    add_message(@session, content: "Refactor the billing service", at: Time.utc(2026, 8, 2, 4, 5, 6))

    get session_url(@session)

    assert_response :success
    assert_match "Refactor the billing service", response.body
    assert_match "Tadas", response.body
    assert_match "Zimmer web UI", response.body
    assert_match "2026-08-02 04:05 UTC", response.body
    assert_select "span.bg-indigo-100", text: /this session/
  end

  # A message said elsewhere must never read as a turn in this session.
  test "a message from elsewhere is distinguished and links its authoring session" do
    router = spawn_session(title: "Route it", agent_root: "zimmer-router")
    worker = spawn_session(parent: router)
    add_message(router, content: "original intent", at: 1.hour.ago)

    get session_url(worker)

    assert_response :success
    assert_match "original intent", response.body
    assert_select "span.bg-gray-100", text: /elsewhere/
    assert_select "a[href=?]", session_path(router), text: "##{router.id}"
    assert_match "context about original intent, not an instruction to this session", response.body
  end

  # The downward walk, on the panel: an ancestor sees what a human said to the
  # sessions it spawned.
  test "a message said to a descendant is shown in an ancestor's panel" do
    router = spawn_session(title: "Route it", agent_root: "zimmer-router")
    worker = spawn_session(parent: router, title: "Do it", agent_root: "zimmer")
    add_message(worker, content: "said to the worker, not the router", at: 1.hour.ago)

    get session_url(router)

    assert_response :success
    assert_match "said to the worker, not the router", response.body
    assert_select "span.bg-gray-100", text: /elsewhere/
    assert_select "a[href=?]", session_path(worker), text: "##{worker.id}"
  end

  # The header states the scope the record was gathered over. Reading only "1 in
  # this session" is what makes a hierarchy-wide panel look like a per-session
  # one, so both counts are stated even when one of them is zero.
  test "the human-messages header states both counts even when nothing was said elsewhere" do
    add_message(@session, content: "only message in the tree")

    get session_url(@session)

    assert_response :success
    assert_match "1 message in this session · 0 elsewhere in the hierarchy", response.body
  end

  test "the human-messages header counts messages said elsewhere in the hierarchy" do
    router = spawn_session(title: "Route it")
    worker = spawn_session(parent: router)
    add_message(router, content: "original intent", at: 2.hours.ago)
    add_message(worker, content: "and one said here", at: 1.hour.ago)

    get session_url(worker)

    assert_response :success
    assert_match "1 message in this session · 1 elsewhere in the hierarchy", response.body
  end

  # Both halves of the header survive a plural here-count.
  test "the human-messages header states both counts with a plural here-count" do
    add_message(@session, content: "first", at: 2.hours.ago)
    add_message(@session, content: "second", at: 1.hour.ago)

    get session_url(@session)

    assert_response :success
    assert_match "2 messages in this session · 0 elsewhere in the hierarchy", response.body
    refute_match "in this sessions", response.body
  end

  test "a Slack message links back to Slack" do
    message = add_message(@session, content: "ship it", author: "juliehazz", channel: HumanMessage::SLACK)
    message.update_column(:provenance, {
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
    add_message(@session, content: "<script>alert('x')</script>")

    get session_url(@session)

    assert_response :success
    refute_match "<script>alert('x')</script>", response.body
    assert_match "&lt;script&gt;", response.body
  end
end
