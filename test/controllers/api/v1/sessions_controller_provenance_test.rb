require "test_helper"

# The session hierarchy and human messages on the REST surface.
#
# Siblings of `session`, not keys inside it: `session` means one shape on every
# response that carries it, and these cost queries the index would pay per card.
class Api::V1::SessionsControllerProvenanceTest < ActionDispatch::IntegrationTest
  setup do
    @api_key = "test_api_key_12345"
    ENV["API_KEYS"] = @api_key
    @headers = { "X-API-Key" => @api_key }
    @session = sessions(:running)
  end

  teardown { ENV.delete("API_KEYS") }

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
      occurred_at: at,
      provenance: { "entry_point" => "web_ui.follow_up" }
    )
  end

  test "show carries an empty human_messages array when nothing was human-authored" do
    get "/api/v1/sessions/#{@session.id}", headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert json.key?("human_messages"), "human_messages must always be present on show"
    assert_empty json["human_messages"]
    refute json["session"].key?("human_messages"), "`session` must keep one shape across the API"
  end

  test "show carries the session hierarchy" do
    router = spawn_session(title: "Route it", agent_root: "zimmer-router")
    worker = spawn_session(parent: router, title: "Do it", agent_root: "zimmer")

    get "/api/v1/sessions/#{worker.id}", headers: @headers

    assert_response :success
    hierarchy = JSON.parse(response.body)["session_hierarchy"]
    assert_equal router.id, hierarchy["origin_session_id"]
    assert_equal false, hierarchy["truncated"]

    nodes = hierarchy["nodes"]
    assert_equal [ router.id, worker.id ], nodes.map { |n| n["id"] }
    assert_equal "Route it", nodes.first["title"]
    assert_equal "zimmer-router", nodes.first["agent_root"]
    assert_equal 0, nodes.first["depth"]
    assert_equal false, nodes.first["current"]
    assert_equal 1, nodes.last["depth"]
    assert_equal true, nodes.last["current"]
    assert_equal router.id, nodes.last["parent_session_id"]
    assert_equal [ router.id ], hierarchy["root_session_ids"]
    assert_equal [], nodes.last["uncle_session_ids"]
  end

  test "show carries uncle edges alongside the spawn edges" do
    senior = spawn_session(title: "Senior", agent_root: "zimmer-router")
    target = spawn_session(title: "Target", agent_root: "zimmer")
    SessionUncleLink.create!(session: target, uncle_session: senior, source: "test")

    get "/api/v1/sessions/#{target.id}", headers: @headers

    assert_response :success
    hierarchy = JSON.parse(response.body)["session_hierarchy"]

    # The spawn origin is unchanged — target was spawned by nobody, so it is its
    # own — while the uncle contributes a second root.
    assert_equal target.id, hierarchy["origin_session_id"]
    assert_includes hierarchy["root_session_ids"], senior.id

    node = hierarchy["nodes"].find { |n| n["id"] == target.id }
    assert_equal [ senior.id ], node["uncle_session_ids"]
    assert_nil node["parent_session_id"]
  end

  test "show renders a message said to this session with its full provenance" do
    add_message(@session, content: "Refactor the billing service", at: Time.utc(2026, 8, 2, 4, 5, 6))

    get "/api/v1/sessions/#{@session.id}", headers: @headers

    assert_response :success
    entry = JSON.parse(response.body)["human_messages"].first
    assert_equal "here", entry["origin"]
    assert_equal "tadasant", entry["author"]
    assert_equal "Tadas", entry["author_display_name"]
    assert_equal "web_ui", entry["channel"]
    assert_equal "Zimmer web UI", entry["channel_label"]
    assert_equal @session.id, entry["authored_in_session_id"]
    assert_equal "web_ui.follow_up", entry["entry_point"]
    assert_equal "Refactor the billing service", entry["content"]
    assert_equal "2026-08-02T04:05:06Z", entry["occurred_at"]
  end

  test "show marks a message said elsewhere and names its session" do
    router = spawn_session(title: "Route it", agent_root: "zimmer-router")
    worker = spawn_session(parent: router)
    add_message(router, content: "original intent", at: 1.hour.ago)

    get "/api/v1/sessions/#{worker.id}", headers: @headers

    entry = JSON.parse(response.body)["human_messages"].first
    assert_equal "elsewhere", entry["origin"]
    assert_equal router.id, entry["authored_in_session_id"]
    assert_includes entry["authored_in"], "session ##{router.id}"
  end

  test "index carries neither the hierarchy nor the messages" do
    add_message(@session, content: "something")

    get "/api/v1/sessions", headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    refute json.key?("human_messages"), "index must stay cheap — no per-card provenance queries"
    refute json.key?("session_hierarchy"), "index must stay cheap — no per-card provenance queries"
    json["sessions"].each do |s|
      refute s.key?("human_messages")
      refute s.key?("session_hierarchy")
    end
  end
end
