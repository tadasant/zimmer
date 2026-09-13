require "test_helper"

# Covers the dashboard's Advanced Search behavior:
#   - filtering sessions by agent root
#   - a search narrowing the board in place rather than replacing it with a
#     separate results presentation
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

    # Belongs to "zimmer" via the explicit metadata key (how new sessions record
    # their root).
    @zimmer_session = Session.create!(
      git_root: "https://github.com/tadasant/zimmer.git",
      prompt: "Zimmer session",
      title: "Zimmer Session",
      status: :needs_input,
      metadata: { "agent_root_key" => "zimmer" }
    )

    # Belongs to "zimmer" via git_root + subdirectory only (an older session created
    # before agent_root_key was persisted in metadata).
    @zimmer_legacy_session = Session.create!(
      git_root: "https://github.com/tadasant/zimmer.git",
      prompt: "Zimmer legacy session",
      title: "Zimmer Legacy Session",
      status: :needs_input
    )

    # Belongs to a different root, and says so explicitly. Its git_root and
    # subdirectory are identical to the two above -- since #67 every shipped root
    # sits at the root of this one repo, so the key is the only thing telling them
    # apart, which is exactly what the filter has to honour.
    @other_root_session = Session.create!(
      git_root: "https://github.com/tadasant/zimmer.git",
      prompt: "General agent session",
      title: "General Agent Session",
      status: :needs_input,
      metadata: { "agent_root_key" => "general-agent" }
    )
  end

  test "filtering by agent root returns only that root's sessions" do
    get root_url(agent_root: "zimmer")
    assert_response :success

    # Both the metadata-keyed and the legacy URL+subdirectory session match; the
    # session explicitly keyed to another root does not.
    assert_select "#user_view_list li[id^='user_view_row_']", count: 2
    assert_select "#user_view_row_#{@zimmer_session.id}"
    assert_select "#user_view_row_#{@zimmer_legacy_session.id}"
    assert_select "#user_view_row_#{@other_root_session.id}", count: 0
  end

  test "filtering by a different agent root returns its sessions" do
    get root_url(agent_root: "general-agent")
    assert_response :success

    # Bounded, so an extra row leaking into this filter fails rather than passing
    # the three per-row assertions below.
    assert_select "#user_view_list li[id^='user_view_row_']", count: 2
    assert_select "#user_view_row_#{@other_root_session.id}"
    # The `zimmer`-keyed session is excluded on its key. The key-LESS legacy row is
    # not: since #67 every root shares one (url, subdirectory), so the fallback
    # cannot tell which of them a row with no key belongs to, and it matches both.
    assert_select "#user_view_row_#{@zimmer_session.id}", count: 0
    assert_select "#user_view_row_#{@zimmer_legacy_session.id}"
  end

  test "filtering by an unknown agent root returns no sessions" do
    get root_url(agent_root: "does-not-exist")
    assert_response :success

    # The board's own placeholder rather than the page-level empty state: the User
    # view keeps its list in the DOM whether or not it has rows, so that a Trash
    # the operator undoes has somewhere to put the row back.
    assert_select "#user_view_list li[id^='user_view_row_']", count: 0
    assert_select "[data-user-view-target='empty']", text: /No sessions match these filters/
  end

  # A search is a NARROWING of the board, not a different screen. Bouncing the
  # operator into a separate results presentation is exactly what the User view
  # exists to stop: they lose the row controls they were working down the page.
  test "an active search narrows the board in place rather than replacing it" do
    get root_url(agent_root: "zimmer")
    assert_response :success

    assert_select "#user_view_list"
    assert_select "#user_view_row_#{@zimmer_session.id}"
    assert_select "#user_view_row_#{@other_root_session.id}", count: 0
  end

  test "a search reaches every status when none is ticked, and narrows when one is" do
    @zimmer_legacy_session.update!(status: :archived)

    # Nothing ticked: the search spans every status, trash included.
    get root_url(every_status_params(agent_root: "zimmer"))
    assert_response :success
    assert_select "#user_view_list li[id^='user_view_row_']", count: 2

    # Naming one status narrows the same search to it.
    get root_url(every_status_params(agent_root: "zimmer", status: [ @zimmer_session.status ]))
    assert_response :success
    assert_select "#user_view_list li[id^='user_view_row_']", count: 1
    assert_select "#user_view_row_#{@zimmer_session.id}"
  end

  test "a text query spans the trash when no status is ticked" do
    archived = Session.create!(
      git_root: "https://github.com/tadasant/zimmer.git",
      prompt: "trashed match",
      title: "Findme Trashed"
    )
    archived.update!(status: :archived)
    Session.create!(
      git_root: "https://github.com/tadasant/zimmer.git",
      prompt: "active match",
      title: "Findme Active",
      status: :needs_input
    )

    get root_url(every_status_params(q: "Findme"))
    assert_response :success
    assert_select "#user_view_list li[id^='user_view_row_']", count: 2
  end

  test "agent root filter and text query combine" do
    @zimmer_session.update!(title: "Special Zimmer")

    get root_url(agent_root: "zimmer", q: "Special")
    assert_response :success

    assert_select "#user_view_list li[id^='user_view_row_']", count: 1
    assert_select "#user_view_row_#{@zimmer_session.id}"
  end

  test "an explicit metadata key wins over a matching git_root + subdirectory" do
    # @other_root_session's URL and (absent) subdirectory match the `zimmer` root
    # exactly, but its metadata explicitly assigns it to `general-agent`. It must
    # resolve to `general-agent` only -- the URL fallback is disabled whenever an
    # explicit key is present (parity with AgentRootsConfig.find_for_session).
    get root_url(agent_root: "general-agent")
    assert_response :success
    assert_select "#user_view_row_#{@other_root_session.id}"

    get root_url(agent_root: "zimmer")
    assert_response :success
    assert_select "#user_view_row_#{@other_root_session.id}", count: 0
  end
end
