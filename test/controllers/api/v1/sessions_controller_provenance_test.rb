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
    # The node a consumer rebuilds the tree from. `rest-api.md` tells them to use
    # this rather than infer a parent from `depth` plus array order, which is the
    # inference that made every child of a sibling batch read as a child of the
    # last sibling (#571).
    assert_nil nodes.first["render_parent_session_id"], "a root hangs from nothing"
    assert_equal router.id, nodes.last["render_parent_session_id"]
    assert_equal true, nodes.last["spawn_edge"]
  end

  # A batch of siblings, each with one child: the array order and every
  # `render_parent_session_id` have to agree with who actually spawned whom.
  test "show attributes each sibling's child to that sibling" do
    trigger = spawn_session(title: "Trigger", agent_root: "zimmer-router")
    routers = Array.new(4) { |i| spawn_session(parent: trigger, title: "Router #{i}", agent_root: "zimmer-router") }
    children = routers.map { |r| spawn_session(parent: r, title: "Child of #{r.id}", agent_root: "zimmer") }

    get "/api/v1/sessions/#{routers.last.id}", headers: @headers

    assert_response :success
    nodes = JSON.parse(response.body)["session_hierarchy"]["nodes"].index_by { |n| n["id"] }

    routers.zip(children).each do |router, child|
      assert_equal router.id, nodes[child.id]["render_parent_session_id"]
      assert_equal true, nodes[child.id]["spawn_edge"]
    end
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

  # An uncle-drawn node: its position in `nodes[]` is not a spawn edge, and the
  # payload says so rather than letting a consumer infer one from the ordering.
  test "show marks a node drawn under an uncle rather than a spawn parent" do
    origin = spawn_session(title: "Origin", agent_root: "zimmer-router")
    spawn_parent = spawn_session(parent: origin, title: "Spawn parent", agent_root: "zimmer-router")
    junior = spawn_session(parent: spawn_parent, title: "Junior", agent_root: "zimmer")
    senior = spawn_session(title: "Senior", agent_root: "zimmer-router")
    SessionUncleLink.create!(session: junior, uncle_session: senior, source: "test")

    get "/api/v1/sessions/#{junior.id}", headers: @headers

    assert_response :success
    node = JSON.parse(response.body)["session_hierarchy"]["nodes"].find { |n| n["id"] == junior.id }

    assert_equal senior.id, node["render_parent_session_id"]
    assert_equal spawn_parent.id, node["parent_session_id"], "the spawn edge is still reported"
    assert_equal false, node["spawn_edge"]
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
