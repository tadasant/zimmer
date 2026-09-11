# frozen_string_literal: true

require "test_helper"

# DELETE /api/v1/sessions/:session_id/uncle_links/:uncle_id (#299).
#
# The endpoint's contract is narrow on purpose: one edge, named by direction, and
# a 404 rather than a 204 when it is not there. The graph semantics are the
# service's and are tested in Sessions::RemoveUncleEdgeTest.
class Api::V1::UncleLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key

    @junior = sessions(:needs_input)
    @uncle = sessions(:waiting)
    SessionUncleLink.delete_all
    @link = SessionUncleLink.create!(
      session: @junior, uncle_session: @uncle, source: "api_v1:sessions.follow_up"
    )
  end

  teardown { ENV.delete("API_KEYS") }

  def edge?(junior, uncle)
    SessionUncleLink.exists?(session_id: junior.id, uncle_session_id: uncle.id)
  end

  # --- Authentication --------------------------------------------------------

  test "returns 401 without an API key" do
    delete api_v1_session_uncle_link_path(@junior, @uncle)

    assert_response :unauthorized
    assert edge?(@junior, @uncle)
  end

  test "returns 401 with an invalid API key" do
    delete api_v1_session_uncle_link_path(@junior, @uncle), headers: { "X-API-Key" => "invalid" }

    assert_response :unauthorized
    assert edge?(@junior, @uncle)
  end

  # --- Success ---------------------------------------------------------------

  test "removes the named edge and answers 204" do
    delete api_v1_session_uncle_link_path(@junior, @uncle), headers: @headers

    assert_response :no_content
    assert_not edge?(@junior, @uncle)
  end

  test "accepts a slug for either end, like every other session parameter" do
    @junior.update!(slug: "the-junior-20260911-1102")
    @uncle.update!(slug: "the-senior-20260911-1103")

    delete api_v1_session_uncle_link_path(@junior.slug, @uncle.slug), headers: @headers

    assert_response :no_content
    assert_not edge?(@junior, @uncle)
  end

  test "records the declared acting session on both timelines" do
    actor = sessions(:running)

    delete api_v1_session_uncle_link_path(@junior, @uncle),
           params: { acting_session_id: actor.id }, headers: @headers

    assert_response :no_content
    [ @junior, @uncle ].each do |session|
      log = session.logs.reload.where("content LIKE ?", "%Uncle edge removed%").last
      assert_not_nil log, "session ##{session.id} has no record of the removal"
      assert_includes log.content, "session ##{actor.id} via the REST API"
      assert_includes log.content, "api_v1:sessions.uncle_links.destroy"
    end
  end

  test "an undeclared caller is logged as exactly that" do
    delete api_v1_session_uncle_link_path(@junior, @uncle), headers: @headers

    log = @junior.logs.reload.where("content LIKE ?", "%Uncle edge removed%").last
    assert_includes log.content, "an undeclared REST API caller"
  end

  # --- Failure ---------------------------------------------------------------

  # A 204 here would tell a caller an edge is gone when it is not — see #299 for
  # why that is the expensive answer.
  test "a non-existent edge is 404, not a silent success" do
    other = sessions(:running)

    delete api_v1_session_uncle_link_path(@junior, other), headers: @headers

    assert_response :not_found
    assert_includes JSON.parse(response.body)["message"], "No uncle edge"
  end

  test "the inverted direction is 404 and names the direction that exists" do
    delete api_v1_session_uncle_link_path(@uncle, @junior), headers: @headers

    assert_response :not_found
    assert_includes JSON.parse(response.body)["message"], "points the other way"
    assert edge?(@junior, @uncle), "the edge that does exist must survive"
  end

  test "an unknown uncle is 404" do
    delete api_v1_session_uncle_link_path(@junior, 99_999_999), headers: @headers

    assert_response :not_found
    assert edge?(@junior, @uncle)
  end

  test "an unknown session is 404" do
    delete api_v1_session_uncle_link_path(99_999_999, @uncle), headers: @headers

    assert_response :not_found
    assert edge?(@junior, @uncle)
  end

  # The write path has no twin here, deliberately: edges are created by
  # Sessions::RecordUncleEdge as a side effect of a queue or interrupt, which is
  # where the acyclicity invariant lives.
  test "there is no way to create or list an uncle edge through this resource" do
    other = sessions(:running)

    post "/api/v1/sessions/#{@junior.id}/uncle_links",
         params: { uncle_session_id: other.id }, headers: @headers
    assert_response :not_found

    get "/api/v1/sessions/#{@junior.id}/uncle_links", headers: @headers
    assert_response :not_found

    assert_not edge?(@junior, other), "POST must not have written an edge"
  end
end
