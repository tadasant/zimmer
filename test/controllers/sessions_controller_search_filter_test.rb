require "test_helper"

# Covers the dashboard's Advanced Search behavior:
#   - filtering sessions by agent root
#   - rendering a flat results list (and hiding the category grid) when a search is active
#   - how the status filter composes with a search
#
# The fixtures sit in `needs_input` so they are visible under the dashboard's default
# filter; a search does not widen the status filter, so a test about search would
# otherwise be asserting the filter instead.
class SessionsControllerSearchFilterTest < ActionDispatch::IntegrationTest
  setup do
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    # Belongs to "agent-orchestrator" via the explicit metadata key (how new sessions
    # record their root).
    @zimmer_session = Session.create!(
      git_root: "https://github.com/tadasant/zimmer-catalog.git",
      subdirectory: "agents/agent-orchestrator",
      prompt: "Zimmer session",
      title: "Zimmer Session",
      status: :needs_input,
      metadata: { "agent_root_key" => "agent-orchestrator" }
    )

    # Belongs to "agent-orchestrator" via git_root + subdirectory only (an older session
    # created before agent_root_key was persisted in metadata).
    @zimmer_legacy_session = Session.create!(
      git_root: "https://github.com/tadasant/zimmer-catalog.git",
      subdirectory: "agents/agent-orchestrator",
      prompt: "Zimmer legacy session",
      title: "Zimmer Legacy Session",
      status: :needs_input
    )

    # Belongs to a different root ("agents").
    @agents_session = Session.create!(
      git_root: "https://github.com/tadasant/zimmer-catalog.git",
      subdirectory: "agents",
      prompt: "Agents session",
      title: "Agents Session",
      status: :needs_input,
      metadata: { "agent_root_key" => "agents" }
    )
  end

  test "filtering by agent root returns only that root's sessions" do
    get root_url(agent_root: "agent-orchestrator")
    assert_response :success

    # Both the metadata-keyed and the legacy URL+subdirectory session match; the
    # "agents" session does not.
    assert_select "#sessions_grid turbo-frame", count: 2
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(@zimmer_session)}"
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(@zimmer_legacy_session)}"
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(@agents_session)}", count: 0
  end

  test "filtering by a different agent root returns only its sessions" do
    get root_url(agent_root: "agents")
    assert_response :success

    assert_select "#sessions_grid turbo-frame", count: 1
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(@agents_session)}"
  end

  test "filtering by an unknown agent root returns no sessions" do
    get root_url(agent_root: "does-not-exist")
    assert_response :success

    assert_match(/No sessions found/, response.body)
  end

  test "an active search renders the flat results list and hides the category grid" do
    get root_url(agent_root: "agent-orchestrator")
    assert_response :success

    # Flat results section present; category sections (Uncategorized + drag-and-drop) absent.
    assert_select "#search_results"
    assert_select "#uncategorized_section", count: 0
    assert_select "[data-controller~='category-dnd']", count: 0
  end

  test "no search renders the category grid and not the flat results list" do
    get root_url
    assert_response :success

    assert_select "#uncategorized_section"
    assert_select "[data-controller~='category-dnd']"
    assert_select "#search_results", count: 0
  end

  test "a search reaches every status when none is ticked, and narrows when one is" do
    @zimmer_legacy_session.update!(status: :archived)

    # Nothing ticked: the search spans every status, trash included.
    get root_url(every_status_params(agent_root: "agent-orchestrator"))
    assert_response :success
    assert_select "#sessions_grid turbo-frame", count: 2

    # Naming one status narrows the same search to it.
    get root_url(every_status_params(agent_root: "agent-orchestrator", status: [ @zimmer_session.status ]))
    assert_response :success
    assert_select "#sessions_grid turbo-frame", count: 1
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(@zimmer_session)}"
  end

  test "a text query activates the flat list, and spans the trash when no status is ticked" do
    archived = Session.create!(
      git_root: "https://github.com/tadasant/zimmer-catalog.git",
      prompt: "trashed match",
      title: "Findme Trashed"
    )
    archived.update!(status: :archived)
    Session.create!(
      git_root: "https://github.com/tadasant/zimmer-catalog.git",
      prompt: "active match",
      title: "Findme Active",
      status: :needs_input
    )

    get root_url(every_status_params(q: "Findme"))
    assert_response :success
    assert_select "#search_results"
    assert_select "#sessions_grid turbo-frame", count: 2
  end

  test "agent root filter and text query combine" do
    @zimmer_session.update!(title: "Special Zimmer")

    get root_url(agent_root: "agent-orchestrator", q: "Special")
    assert_response :success

    assert_select "#sessions_grid turbo-frame", count: 1
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(@zimmer_session)}"
  end

  test "an explicit metadata key wins over a mismatched git_root + subdirectory" do
    # This session's URL + subdirectory match the agent-orchestrator root, but its
    # metadata explicitly assigns it to "agents". It must resolve to "agents" only —
    # the URL fallback is disabled when an explicit key is present (parity with
    # AgentRootsConfig.find_for_session).
    mismatched = Session.create!(
      git_root: "https://github.com/tadasant/zimmer-catalog.git",
      subdirectory: "agents/agent-orchestrator",
      prompt: "Mismatched session",
      title: "Mismatched Session",
      status: :needs_input,
      metadata: { "agent_root_key" => "agents" }
    )

    get root_url(agent_root: "agents")
    assert_response :success
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(mismatched)}"

    get root_url(agent_root: "agent-orchestrator")
    assert_response :success
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(mismatched)}", count: 0
  end
end
