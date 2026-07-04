require "test_helper"

class SessionDependencyGraphServiceTest < ActiveSupport::TestCase
  setup do
    # Clean up all sessions to start fresh (order matters due to foreign keys)
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all
  end

  test "returns empty graph when no sessions exist" do
    graph = SessionDependencyGraphService.call

    assert_equal [], graph[:nodes]
    assert_equal [], graph[:edges]
    assert_equal [], graph[:roots]
    assert_equal 0, graph[:summary][:total]
  end

  test "classifies user-triggered sessions (no spawned_by)" do
    session = create_session(status: :running, custom_metadata: {})

    graph = SessionDependencyGraphService.call

    assert_equal 1, graph[:nodes].size
    node = graph[:nodes].first
    assert_equal session.id, node[:id]
    assert_equal "user-triggered", node[:origin_type]
    assert_nil node[:parent_session_id]
    assert_includes graph[:roots], session.id
  end

  test "classifies heartbeat-triggered sessions" do
    session = create_session(
      status: :running,
      custom_metadata: { "spawned_by" => "ao-heartbeat" }
    )

    graph = SessionDependencyGraphService.call

    node = graph[:nodes].first
    assert_equal "heartbeat-triggered", node[:origin_type]
    assert_equal "ao-heartbeat", node[:spawned_by]
  end

  test "classifies router-triggered sessions" do
    session = create_session(
      status: :running,
      custom_metadata: { "spawned_by" => "ao-router" }
    )

    graph = SessionDependencyGraphService.call

    node = graph[:nodes].first
    assert_equal "router-triggered", node[:origin_type]
  end

  test "classifies agent-triggered sessions with custom spawned_by" do
    session = create_session(
      status: :running,
      custom_metadata: { "spawned_by" => "some-custom-agent" }
    )

    graph = SessionDependencyGraphService.call

    node = graph[:nodes].first
    assert_equal "agent-triggered", node[:origin_type]
  end

  test "builds spawned edges from parent_session_id column" do
    parent = create_session(status: :running, custom_metadata: {})
    child = create_session(
      status: :running,
      parent_session_id: parent.id,
      custom_metadata: { "spawned_by" => "ao-heartbeat" }
    )

    graph = SessionDependencyGraphService.call

    spawned_edges = graph[:edges].select { |e| e[:type] == "spawned" }
    assert_equal 1, spawned_edges.size

    edge = spawned_edges.first
    assert_equal parent.id, edge[:from_id]
    assert_equal child.id, edge[:to_id]
    assert_equal "spawned", edge[:label]
  end

  test "builds spawned edges for router-spawned sessions" do
    parent = create_session(status: :running, custom_metadata: {})
    child = create_session(
      status: :running,
      parent_session_id: parent.id,
      custom_metadata: { "spawned_by" => "ao-router" }
    )

    graph = SessionDependencyGraphService.call

    spawned_edges = graph[:edges].select { |e| e[:type] == "spawned" }
    assert_equal 1, spawned_edges.size
    assert_equal parent.id, spawned_edges.first[:from_id]
    assert_equal child.id, spawned_edges.first[:to_id]
  end

  test "does not create spawned edge when parent is not in graph" do
    child = create_session(
      status: :running,
      parent_session_id: 999999,
      custom_metadata: { "spawned_by" => "ao-heartbeat" }
    )

    graph = SessionDependencyGraphService.call

    assert_equal 0, graph[:edges].size
    assert_includes graph[:roots], child.id
  end

  test "detects blocking references in prompt" do
    blocker = create_session(status: :running, custom_metadata: {})
    blocked = create_session(
      status: :needs_input,
      prompt: "Wait for session ##{blocker.id} to complete before proceeding",
      custom_metadata: {}
    )

    graph = SessionDependencyGraphService.call

    blocking_edges = graph[:edges].select { |e| e[:type] == "blocked_by" }
    assert_equal 1, blocking_edges.size
    assert_equal blocked.id, blocking_edges.first[:from_id]
    assert_equal blocker.id, blocking_edges.first[:to_id]
  end

  test "detects blocking references in goal" do
    blocker = create_session(status: :running, custom_metadata: {})
    blocked = create_session(
      status: :running,
      goal: "blocked on session #{blocker.id}",
      custom_metadata: {}
    )

    graph = SessionDependencyGraphService.call

    blocking_edges = graph[:edges].select { |e| e[:type] == "blocked_by" }
    assert_equal 1, blocking_edges.size
  end

  test "does not self-reference in blocking detection" do
    session = create_session(
      status: :running,
      prompt: "This is session ##{Session.maximum(:id).to_i + 1}",
      custom_metadata: {}
    )
    # Update prompt with the actual ID
    session.update!(prompt: "This is session ##{session.id}")

    graph = SessionDependencyGraphService.call

    blocking_edges = graph[:edges].select { |e| e[:type] == "blocked_by" }
    assert_equal 0, blocking_edges.size
  end

  test "excludes archived sessions by default" do
    active = create_session(status: :running, custom_metadata: {})
    archived = create_session(status: :archived, custom_metadata: {})

    graph = SessionDependencyGraphService.call

    ids = graph[:nodes].map { |n| n[:id] }
    assert_includes ids, active.id
    assert_not_includes ids, archived.id
  end

  test "includes archived sessions when requested" do
    active = create_session(status: :running, custom_metadata: {})
    archived = create_session(status: :archived, custom_metadata: {})

    graph = SessionDependencyGraphService.call(include_archived: true)

    ids = graph[:nodes].map { |n| n[:id] }
    assert_includes ids, active.id
    assert_includes ids, archived.id
  end

  test "correctly identifies root nodes" do
    root1 = create_session(status: :running, custom_metadata: {})
    root2 = create_session(status: :needs_input, custom_metadata: {})
    child = create_session(
      status: :running,
      parent_session_id: root1.id,
      custom_metadata: { "spawned_by" => "ao-heartbeat" }
    )

    graph = SessionDependencyGraphService.call

    assert_includes graph[:roots], root1.id
    assert_includes graph[:roots], root2.id
    assert_not_includes graph[:roots], child.id
  end

  test "builds multi-level invocation chain" do
    heartbeat = create_session(status: :running, custom_metadata: { "spawned_by" => "ao-heartbeat" })
    router = create_session(
      status: :running,
      parent_session_id: heartbeat.id,
      custom_metadata: { "spawned_by" => "ao-heartbeat" }
    )
    worker = create_session(
      status: :running,
      parent_session_id: router.id,
      custom_metadata: { "spawned_by" => "ao-router" }
    )

    graph = SessionDependencyGraphService.call

    spawned_edges = graph[:edges].select { |e| e[:type] == "spawned" }
    assert_equal 2, spawned_edges.size

    # heartbeat -> router
    assert spawned_edges.any? { |e| e[:from_id] == heartbeat.id && e[:to_id] == router.id }
    # router -> worker
    assert spawned_edges.any? { |e| e[:from_id] == router.id && e[:to_id] == worker.id }

    # Only heartbeat is a root
    assert_equal [ heartbeat.id ], graph[:roots]
  end

  test "summary includes counts by status and origin_type" do
    create_session(status: :running, custom_metadata: {})
    create_session(status: :running, custom_metadata: { "spawned_by" => "ao-heartbeat" })
    create_session(status: :needs_input, custom_metadata: { "spawned_by" => "ao-router" })
    create_session(status: :failed, custom_metadata: {})

    graph = SessionDependencyGraphService.call

    assert_equal 4, graph[:summary][:total]
    assert_equal 2, graph[:summary][:by_status]["running"]
    assert_equal 1, graph[:summary][:by_status]["needs_input"]
    assert_equal 1, graph[:summary][:by_status]["failed"]
    assert_equal 2, graph[:summary][:by_origin_type]["user-triggered"]
    assert_equal 1, graph[:summary][:by_origin_type]["heartbeat-triggered"]
    assert_equal 1, graph[:summary][:by_origin_type]["router-triggered"]
  end

  test "includes node metadata fields" do
    session = create_session(
      status: :running,
      title: "Test Session",
      slug: "test-session-slug",
      is_autonomous: true,
      custom_metadata: { "spawned_by" => "ao-heartbeat" }
    )

    graph = SessionDependencyGraphService.call

    node = graph[:nodes].first
    assert_equal session.id, node[:id]
    assert_equal "test-session-slug", node[:slug]
    assert_equal "Test Session", node[:title]
    assert_equal "running", node[:status]
    assert_equal true, node[:is_autonomous]
    assert_equal "heartbeat-triggered", node[:origin_type]
    assert_equal "ao-heartbeat", node[:spawned_by]
    assert node[:created_at].present?
    assert node[:updated_at].present?
  end

  private

  def create_session(status:, custom_metadata:, prompt: "Test prompt", title: nil, slug: nil, is_autonomous: true, goal: nil, parent_session_id: nil)
    Session.create!(
      agent_runtime: "claude_code",
      status: status,
      prompt: prompt,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      mcp_servers: [],
      custom_metadata: custom_metadata,
      parent_session_id: parent_session_id,
      title: title,
      slug: slug,
      is_autonomous: is_autonomous,
      goal: goal
    )
  end
end
