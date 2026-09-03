require "test_helper"
require "mocha/minitest"

# The REST half of board visibility: PATCH /api/v1/sessions/:id/visibility, the
# fields on the serialized session, and the OPTIONAL listing filter.
#
# The listing default is the load-bearing one. Agents read this endpoint to find
# out whether a piece of work already has a session; a session a human tidied off
# their dashboard must still be found by that check, or Zimmer produces duplicate
# work with no visible cause.
class Api::V1::SessionsVisibilityTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key

    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  def make_session(**attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    }.merge(attrs))
  end

  test "a serialized session carries both the stored and the effective visibility" do
    session = make_session(visibility: SessionVisibility::SNOOZED, snoozed_until: 2.days.from_now)

    get api_v1_session_path(session), headers: @headers

    assert_response :success
    json = JSON.parse(response.body)["session"]
    assert_equal "snoozed", json["visibility"]
    assert_equal "snoozed", json["effective_visibility"]
    assert_not_nil json["snoozed_until"]
  end

  test "an expired snooze serializes as effectively visible" do
    session = make_session(visibility: SessionVisibility::SNOOZED, snoozed_until: 1.hour.ago)

    get api_v1_session_path(session), headers: @headers

    assert_response :success
    json = JSON.parse(response.body)["session"]
    assert_equal "snoozed", json["visibility"], "the stored choice is reported as stored"
    assert_equal "visible", json["effective_visibility"], "an expired snooze reads as visible"
  end

  test "hides a session" do
    session = make_session

    patch visibility_api_v1_session_path(session), params: { visibility: "hidden" }, headers: @headers

    assert_response :success
    assert_equal "hidden", JSON.parse(response.body)["session"]["visibility"]
    assert_equal SessionVisibility::HIDDEN, session.reload.visibility
  end

  test "snoozes with a timezone" do
    session = make_session
    at = Time.use_zone("Europe/Berlin") { 2.days.from_now.change(hour: 9, min: 0) }

    patch visibility_api_v1_session_path(session),
      params: { visibility: "snoozed", snoozed_until: at.strftime("%Y-%m-%dT%H:%M:%S"), timezone: "Europe/Berlin" },
      headers: @headers

    assert_response :success
    assert_equal 9, session.reload.snoozed_until.in_time_zone("Europe/Berlin").hour
  end

  test "rejects an unknown visibility" do
    session = make_session

    patch visibility_api_v1_session_path(session), params: { visibility: "somewhen" }, headers: @headers

    assert_response :unprocessable_entity
    assert_equal SessionVisibility::VISIBLE, session.reload.visibility
  end

  test "setting visibility leaves the lifecycle untouched" do
    session = make_session(status: :waiting, scheduling_class: "spot", precedence: 555)

    assert_no_difference -> { Trigger.count } do
      patch visibility_api_v1_session_path(session), params: { visibility: "hidden" }, headers: @headers
    end

    session.reload
    assert_equal "waiting", session.status
    assert_equal "spot", session.scheduling_class
    assert_equal 555, session.precedence
  end

  # The one that matters: the default listing is unfiltered on this axis.
  test "the listing includes hidden sessions by default" do
    hidden = make_session(visibility: SessionVisibility::HIDDEN, title: "tidied away")

    get api_v1_sessions_path, params: { per_page: 100 }, headers: @headers

    assert_response :success
    ids = JSON.parse(response.body)["sessions"].map { |s| s["id"] }
    assert_includes ids, hidden.id
  end

  test "the listing filters on visibility when asked" do
    on_board = make_session
    hidden = make_session(visibility: SessionVisibility::HIDDEN)

    get api_v1_sessions_path, params: { visibility: "on_board", per_page: 100 }, headers: @headers
    assert_response :success
    ids = JSON.parse(response.body)["sessions"].map { |s| s["id"] }
    assert_includes ids, on_board.id
    assert_not_includes ids, hidden.id

    get api_v1_sessions_path, params: { visibility: "off_board", per_page: 100 }, headers: @headers
    assert_response :success
    ids = JSON.parse(response.body)["sessions"].map { |s| s["id"] }
    assert_includes ids, hidden.id
    assert_not_includes ids, on_board.id
  end
end
