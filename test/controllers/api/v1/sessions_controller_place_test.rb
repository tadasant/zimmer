# frozen_string_literal: true

require "test_helper"

# `place` on the REST surface: the symbolic half of the ranking pair, on both
# write paths. The point of it is that heading the spot queue is ONE request —
# the server resolves the value against the live queue as part of the write —
# rather than a read of the current top followed by a write above it, which can
# be overtaken in between.
#
# Half of these tests are about what `place` must NOT change: a caller sending
# `precedence` alone, or neither field, has to behave exactly as it did before
# the parameter existed.
class Api::V1::SessionsControllerPlaceTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # --- create ---------------------------------------------------------------

  test "create with place top_of_spot lands the session above the current top" do
    top = spot_session(precedence: 400)

    post "/api/v1/sessions",
      params: { agent_root: "zimmer", prompt: "Go", place: SessionPrecedence::PLACE_TOP_OF_SPOT },
      headers: @headers

    assert_response :created
    json = JSON.parse(response.body)["session"]
    assert_equal 400 + SessionPrecedence::SLOT_GAP, json["precedence"]
    assert_equal json["precedence"], Session.find(json["id"]).precedence
    assert_operator json["precedence"], :>, top.precedence, "it heads the queue it was placed into"
  end

  # The reason the value is resolved server-side rather than read and passed
  # back: a top that has since been archived is not the top any more, and a
  # caller working from a stale read would inflate the scale by 90,000.
  test "create with place reads the live queue, not a stale archived top" do
    spot_session(precedence: 90_000, status: :archived)
    spot_session(precedence: 20)

    post "/api/v1/sessions",
      params: { agent_root: "zimmer", prompt: "Go", place: SessionPrecedence::PLACE_TOP_OF_SPOT },
      headers: @headers

    assert_response :created
    assert_equal 20 + SessionPrecedence::SLOT_GAP, JSON.parse(response.body)["session"]["precedence"]
  end

  # A placement beats the parent-inheritance a create would otherwise get, the
  # same way an explicit precedence does.
  test "create with place overrides the just-above-the-parent inheritance" do
    parent = spot_session(precedence: 7)
    spot_session(precedence: 300)

    post "/api/v1/sessions",
      params: {
        agent_root: "zimmer", prompt: "Go", parent_session_id: parent.id,
        place: SessionPrecedence::PLACE_TOP_OF_SPOT
      },
      headers: @headers

    assert_response :created
    assert_equal 300 + SessionPrecedence::SLOT_GAP, JSON.parse(response.body)["session"]["precedence"]
  end

  test "create rejects place and precedence together, and creates nothing" do
    assert_no_difference "Session.count" do
      post "/api/v1/sessions",
        params: {
          agent_root: "zimmer", prompt: "Go",
          place: SessionPrecedence::PLACE_TOP_OF_SPOT, precedence: 1234
        },
        headers: @headers
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Invalid placement", json["error"]
    assert_match(/mutually exclusive/, json["message"])
  end

  test "create rejects a placement it does not know" do
    assert_no_difference "Session.count" do
      post "/api/v1/sessions",
        params: { agent_root: "zimmer", prompt: "Go", place: "bottom_of_spot" },
        headers: @headers
    end

    assert_response :unprocessable_entity
    assert_match(/Unknown place/, JSON.parse(response.body)["message"])
  end

  # --- create: the paths `place` must leave alone ---------------------------

  test "create with precedence alone is untouched by the new parameter" do
    spot_session(precedence: 400)

    post "/api/v1/sessions",
      params: { agent_root: "zimmer", prompt: "Go", precedence: 12 },
      headers: @headers

    assert_response :created
    json = JSON.parse(response.body)["session"]
    assert_equal 12, json["precedence"], "an absolute rank is written as given, not re-resolved"
    assert_equal 12, Session.find(json["id"]).precedence
  end

  test "create with neither field still lands one point above the parent" do
    parent = spot_session(precedence: 7)
    spot_session(precedence: 300)

    post "/api/v1/sessions",
      params: { agent_root: "zimmer", prompt: "Go", parent_session_id: parent.id },
      headers: @headers

    assert_response :created
    assert_equal 7 + SessionPrecedence::CHILD_BUMP, JSON.parse(response.body)["session"]["precedence"]
  end

  test "create with neither field and no parent still lands at the default" do
    spot_session(precedence: 300)

    post "/api/v1/sessions", params: { agent_root: "zimmer", prompt: "Go" }, headers: @headers

    assert_response :created
    assert_equal SessionPrecedence::DEFAULT, JSON.parse(response.body)["session"]["precedence"]
  end

  # --- update ---------------------------------------------------------------

  test "update with place top_of_spot lands the session above the current top" do
    top = spot_session(precedence: 400)
    session = spot_session(precedence: 0)

    patch "/api/v1/sessions/#{session.id}",
      params: { place: SessionPrecedence::PLACE_TOP_OF_SPOT }, headers: @headers

    assert_response :success
    assert_equal 400 + SessionPrecedence::SLOT_GAP, session.reload.precedence
    assert_equal session.precedence, JSON.parse(response.body)["session"]["precedence"]
    assert_equal session, Session.where(id: [ top.id, session.id ]).ranked.first
  end

  # The session must not be measured against itself, or repeating the call would
  # walk it SLOT_GAP higher every time. The runner-up at 100 is what tells a
  # correct exclusion from a fall-through to the nothing-queued branch.
  test "update with place does not measure the session against itself" do
    spot_session(precedence: 100)
    session = spot_session(precedence: 50)

    patch "/api/v1/sessions/#{session.id}",
      params: { place: SessionPrecedence::PLACE_TOP_OF_SPOT }, headers: @headers
    assert_equal 105, session.reload.precedence

    patch "/api/v1/sessions/#{session.id}",
      params: { place: SessionPrecedence::PLACE_TOP_OF_SPOT }, headers: @headers

    assert_equal 105, session.reload.precedence, "a repeat placement is a no-op, not a ratchet"
  end

  # The other half of the self-exclusion: "put this first" is never a request to
  # lower a rank, so a session already on top keeps its number.
  test "update with place never lowers the rank of a session already on top" do
    spot_session(precedence: 10)
    session = spot_session(precedence: 1_000)

    patch "/api/v1/sessions/#{session.id}",
      params: { place: SessionPrecedence::PLACE_TOP_OF_SPOT }, headers: @headers

    assert_response :success
    assert_equal 1_000, session.reload.precedence
  end

  # A placement applies whichever class the session is being moved to, so a
  # demotion can rank the session in the same request.
  test "update can demote a session straight to the head of the queue" do
    spot_session(precedence: 120)
    session = Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::PRIORITY, precedence: 0
    )

    patch "/api/v1/sessions/#{session.id}",
      params: { scheduling_class: "spot", place: SessionPrecedence::PLACE_TOP_OF_SPOT },
      headers: @headers

    assert_response :success
    session.reload
    assert_equal SessionGenesis::SPOT, session.priority_class
    assert_equal 120 + SessionPrecedence::SLOT_GAP, session.precedence
  end

  test "update rejects place and precedence together, and changes nothing" do
    spot_session(precedence: 400)
    session = spot_session(precedence: 5)

    patch "/api/v1/sessions/#{session.id}",
      params: { title: "Renamed", place: SessionPrecedence::PLACE_TOP_OF_SPOT, precedence: 90 },
      headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Invalid placement", json["error"]
    assert_match(/mutually exclusive/, json["message"])

    session.reload
    assert_equal 5, session.precedence
    assert_not_equal "Renamed", session.title, "the whole write is refused, not half of it"
  end

  test "update rejects a placement it does not know" do
    session = spot_session(precedence: 5)

    patch "/api/v1/sessions/#{session.id}", params: { place: "bottom_of_spot" }, headers: @headers

    assert_response :unprocessable_entity
    assert_match(/Unknown place/, JSON.parse(response.body)["message"])
    assert_equal 5, session.reload.precedence
  end

  # --- update: the paths `place` must leave alone ---------------------------

  test "update with precedence alone is untouched by the new parameter" do
    spot_session(precedence: 400)
    session = spot_session(precedence: 5)

    patch "/api/v1/sessions/#{session.id}", params: { precedence: 90 }, headers: @headers

    assert_response :success
    assert_equal 90, session.reload.precedence, "an absolute rank is written as given, not re-resolved"
    assert_equal 90, JSON.parse(response.body)["session"]["precedence"]
  end

  test "update with neither field does not renumber the session" do
    spot_session(precedence: 400)
    session = spot_session(precedence: 5)

    patch "/api/v1/sessions/#{session.id}", params: { title: "Renamed" }, headers: @headers

    assert_response :success
    session.reload
    assert_equal "Renamed", session.title
    assert_equal 5, session.precedence, "a PATCH that touches the title does not touch the queue"
  end

  # An explicit JSON null is "say nothing", not a placement — the same reading
  # MCP gives a blank enum. It must not trip the mutual-exclusion check either.
  test "a null place leaves an absolute precedence alone" do
    session = spot_session(precedence: 5)

    patch "/api/v1/sessions/#{session.id}",
      params: { place: nil, precedence: 90 }.to_json,
      headers: @headers.merge("Content-Type" => "application/json")

    assert_response :success
    assert_equal 90, session.reload.precedence
  end

  private

  def spot_session(precedence:, status: :waiting)
    Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: precedence, status: status
    )
  end
end
