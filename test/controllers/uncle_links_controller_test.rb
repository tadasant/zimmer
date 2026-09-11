# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The browser half of #299: the × on an "also senior" chip in the session-detail
# hierarchy panel.
#
# Two things are specific to this surface and tested nowhere else. The junior is
# the ROW's session, not the page's — the chip is rendered once per session in the
# hierarchy, and the wrong edge is routinely on another row. And the panel that
# repaints is the VIEWER's, because replacing another session's provenance div
# would target an id that is not on the page.
class UncleLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)

    @junior = sessions(:needs_input)
    @uncle = sessions(:waiting)
    SessionUncleLink.delete_all
    SessionUncleLink.create!(
      session: @junior, uncle_session: @uncle, source: "mcp:action_session.follow_up"
    )
  end

  teardown { Mocha::Mockery.instance.teardown }

  def edge?(junior, uncle)
    SessionUncleLink.exists?(session_id: junior.id, uncle_session_id: uncle.id)
  end

  def turbo_headers
    { "Accept" => "text/vnd.turbo-stream.html" }
  end

  # --- The control is rendered --------------------------------------------------

  test "the hierarchy panel renders a detach control on each also-senior chip" do
    get provenance_panel_session_path(@junior)

    assert_response :success
    assert_includes response.body, "also senior:"
    assert_includes response.body, session_uncle_link_path(@junior, @uncle, viewer_id: @junior.id)
    # Named for the operator, not just drawn — the chip is a row of "#N" links and
    # a bare × next to one of them has to say which edge it removes.
    assert_includes response.body, "Remove ##{@uncle.id} as an additional senior of ##{@junior.id}"
  end

  # The chip on the senior's own page names the JUNIOR's row, so the form has to
  # target the junior with the senior's page as the viewer.
  test "a chip on another row targets that row's session, not the page's" do
    get provenance_panel_session_path(@uncle)

    assert_response :success
    assert_includes response.body, session_uncle_link_path(@junior, @uncle, viewer_id: @uncle.id)
  end

  test "a session with no seniors renders no detach control" do
    SessionUncleLink.delete_all

    get provenance_panel_session_path(@junior)

    assert_response :success
    assert_not_includes response.body, "also senior:"
    assert_not_includes response.body, "as an additional senior of"
  end

  # --- Detaching ---------------------------------------------------------------

  test "the detach removes the edge and repaints the viewer's panel" do
    delete session_uncle_link_path(@junior, @uncle, viewer_id: @uncle.id), headers: turbo_headers

    assert_response :success
    assert_not edge?(@junior, @uncle)
    # The viewer's div, because that is the one on the page the click came from.
    assert_includes response.body, %(target="session_#{@uncle.id}_provenance")
    assert_not_includes response.body, "also senior:"
    assert_includes response.body, "Removed ##{@uncle.id} as an additional senior of ##{@junior.id}."
  end

  test "with no viewer the junior's own panel is repainted" do
    delete session_uncle_link_path(@junior, @uncle), headers: turbo_headers

    assert_response :success
    assert_includes response.body, %(target="session_#{@junior.id}_provenance")
  end

  test "a non-turbo detach redirects to the viewer" do
    delete session_uncle_link_path(@junior, @uncle, viewer_id: @uncle.id)

    assert_redirected_to @uncle
    assert_not edge?(@junior, @uncle)
  end

  # A human clicking × is not a session, so the timeline must not name one — the
  # same structural guarantee the write path has, from the other direction.
  test "the removal is recorded as a human action on both timelines" do
    delete session_uncle_link_path(@junior, @uncle), headers: turbo_headers

    [ @junior, @uncle ].each do |session|
      log = session.logs.reload.where("content LIKE ?", "%Uncle edge removed%").last
      assert_not_nil log, "session ##{session.id} has no record of the removal"
      assert_includes log.content, "a human in the web UI"
      assert_includes log.content, "web_ui:session_hierarchy.detach"
      assert_includes log.content, "mcp:action_session.follow_up", "the log must say what wrote the edge"
    end
  end

  # --- Failure ----------------------------------------------------------------

  test "a missing edge repaints the panel with the service's own sentence" do
    other = sessions(:running)

    delete session_uncle_link_path(@junior, other, viewer_id: @junior.id), headers: turbo_headers

    assert_response :success
    # In the stream, not in `flash`: a Turbo response has no next page load to
    # carry one, and writing it to the real flash would show it again later.
    assert_includes response.body, %(target="flash")
    assert_includes response.body,
                    "No uncle edge ##{other.id} → ##{@junior.id}: session ##{other.id} is not recorded as an " \
                    "additional senior of session ##{@junior.id}."
    assert edge?(@junior, @uncle), "an unrelated edge must survive"
  end

  test "the inverted direction is refused and the edge survives" do
    delete session_uncle_link_path(@uncle, @junior, viewer_id: @junior.id), headers: turbo_headers

    assert_response :success
    assert_includes response.body, "points the other way"
    assert edge?(@junior, @uncle)
  end

  # --- No create path ---------------------------------------------------------

  # "A human is never an uncle" is guaranteed by the web UI having no way to
  # declare an acting session at all. This resource must not become one.
  test "the browser cannot create an uncle edge" do
    other = sessions(:running)

    post "/sessions/#{@junior.id}/uncle_links", params: { uncle_session_id: other.id }

    assert_response :not_found
    assert_not edge?(@junior, other)
  end
end
