# frozen_string_literal: true

require "test_helper"

# `scheduling_class` on the REST surface: choosing a class at create, changing it
# afterwards, and both of the fields a session object now carries.
class Api::V1::SessionsControllerSchedulingClassTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  test "create honors an explicit spot over the genesis the parent would give it" do
    parent = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", genesis: SessionGenesis::SLACK)

    post "/api/v1/sessions",
      params: { agent_root: "zimmer", prompt: "Run the batch", parent_session_id: parent.id, scheduling_class: "spot" },
      headers: @headers

    assert_response :created
    json = JSON.parse(response.body)["session"]
    assert_equal SessionGenesis::SLACK, json["genesis"]
    assert_equal "spot", json["scheduling_class"]
    assert_equal "spot", json["priority_class"]
    assert Session.find(json["id"]).spot?
  end

  test "create without the param leaves the class derived" do
    post "/api/v1/sessions", params: { agent_root: "zimmer", prompt: "Go" }, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)["session"]
    assert_nil json["scheduling_class"]
    assert_equal "api", json["genesis"]
    assert_equal "spot", json["priority_class"], "api derives spot"
  end

  test "create accepts a precedence and reports it back" do
    post "/api/v1/sessions",
      params: { agent_root: "zimmer", prompt: "Go", precedence: 1234 },
      headers: @headers

    assert_response :created
    json = JSON.parse(response.body)["session"]
    assert_equal 1234, json["precedence"]
    assert_equal 1234, Session.find(json["id"]).precedence
  end

  test "update moves a session within the spot queue" do
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", precedence: 5)

    patch "/api/v1/sessions/#{session.id}", params: { precedence: 90 }, headers: @headers

    assert_response :success
    assert_equal 90, session.reload.precedence
    assert_equal 90, JSON.parse(response.body)["session"]["precedence"]
  end

  test "an unknown class is a 422 rather than a silent default" do
    post "/api/v1/sessions",
      params: { agent_root: "zimmer", prompt: "Go", scheduling_class: "whenever" },
      headers: @headers

    assert_response :unprocessable_entity
    assert_match(/scheduling class/i, response.body)
  end

  test "update rejects an unknown class" do
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", genesis: SessionGenesis::WEB_UI)

    patch "/api/v1/sessions/#{session.id}", params: { scheduling_class: "whenever" }, headers: @headers

    assert_response :unprocessable_entity
    assert_nil session.reload.scheduling_class
  end

  # Promoting a waiting session starts it, and the response says so. The `start`
  # object is the only place a REST caller learns what the promotion actually did
  # to the session — a promotion that started nothing and one that started a turn
  # are otherwise the same 200.

  def waiting_spot_session(session_id: nil)
    Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "x",
      genesis: SessionGenesis::GITHUB_ISSUE, status: :waiting, session_id: session_id
    )
  end

  test "promoting a waiting session reports the start it performed" do
    session = waiting_spot_session
    assert session.spot?

    patch "/api/v1/sessions/#{session.id}", params: { scheduling_class: "priority" }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "priority", json["session"]["priority_class"]
    assert_equal "started", json["start"]["outcome"]
    assert_match(/next turn is due now/, json["start"]["message"])
  end

  # A refusal is reported rather than swallowed: the promotion went through, the
  # start did not, and a caller that saw only the 200 would think it had.
  test "a promotion whose start is refused says so instead of staying quiet" do
    session = waiting_spot_session(session_id: "cli-abc")
    Sessions::ScheduleWakeUp.call(
      session: session,
      wake_at: 2.hours.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S"),
      prompt: "Check the build"
    )

    patch "/api/v1/sessions/#{session.id}", params: { scheduling_class: "priority" }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "priority", json["session"]["priority_class"]
    assert_equal "refused", json["start"]["outcome"]
    assert_match(/paused/, json["start"]["message"])
  end

  # Nothing to pull forward is not a start, and it is not a refusal either — the
  # promotion leaves a stranded session alone, so there is nothing to report.
  test "a promotion that starts nothing leaves the start key off" do
    session = waiting_spot_session(session_id: "cli-abc")

    patch "/api/v1/sessions/#{session.id}", params: { scheduling_class: "priority" }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "priority", json["session"]["priority_class"]
    assert_not json.key?("start"), "a stranded session was not started, so nothing should be reported"
  end

  # Only the transition INTO priority on a WAITING session starts anything. A
  # session that is not waiting is not a candidate, so no start is attempted.
  test "promoting a session that is not waiting starts nothing" do
    session = Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "x",
      genesis: SessionGenesis::GITHUB_ISSUE, status: :needs_input, session_id: "cli-abc"
    )

    patch "/api/v1/sessions/#{session.id}", params: { scheduling_class: "priority" }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "priority", json["session"]["priority_class"]
    assert_not json.key?("start")
  end

  # An unrelated PATCH must not restart a session that is already priority.
  test "a patch that does not promote starts nothing" do
    session = Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::PRIORITY, status: :waiting
    )

    patch "/api/v1/sessions/#{session.id}", params: { title: "Renamed" }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_not json.key?("start"), "the session was already priority — nothing was promoted"
  end

  test "update moves one session, and null returns it to derived" do
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", genesis: SessionGenesis::GITHUB_ISSUE)
    assert session.spot?

    patch "/api/v1/sessions/#{session.id}", params: { scheduling_class: "priority" }, headers: @headers
    assert_response :success
    assert session.reload.priority?

    patch "/api/v1/sessions/#{session.id}", params: { scheduling_class: "" }, headers: @headers
    assert_response :success
    assert_nil session.reload.scheduling_class
    assert session.spot?
  end
end
