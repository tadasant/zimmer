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

  test "promoting a waiting session reports the start it performed" do
    session = waiting_spot_session
    assert session.spot?

    patch "/api/v1/sessions/#{session.id}", params: { scheduling_class: "priority" }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "priority", json["session"]["priority_class"]
    assert_equal "started", json["start"]["outcome"]
    assert_match(/next turn is due now/, json["start"]["message"])
    assert session.logs.where("content LIKE ?", "%Started now by the REST API promoting it%").exists?
  end

  # A refusal is reported rather than swallowed: the promotion went through, the
  # start did not, and a caller that saw only the 200 would think it had.
  test "a promotion whose start is refused says so instead of staying quiet" do
    session = waiting_spot_session
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
    assert_match(/A pause outranks the queue/, json["start"]["message"])
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
    assert_equal "Renamed", json["session"]["title"]
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

  # --- through Sessions::UpdateSchedulingClass ---------------------------------

  test "a class change is logged on the session, with any rank that moved alongside it" do
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", status: :needs_input,
      scheduling_class: SessionGenesis::PRIORITY, precedence: 0)

    patch "/api/v1/sessions/#{session.id}", params: { scheduling_class: "spot", precedence: 640 }, headers: @headers

    assert_response :success
    assert_equal 640, session.reload.precedence
    contents = session.logs.pluck(:content)
    assert_includes contents, "Scheduling class set via the REST API to spot (was priority)"
    assert_includes contents, "Precedence set via the REST API to 640 (was 0)"
  end

  test "a class change with place never lowers a rank already above the spot queue" do
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 10)
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", status: :needs_input,
      scheduling_class: SessionGenesis::PRIORITY, precedence: 1000)

    patch "/api/v1/sessions/#{session.id}", params: { scheduling_class: "spot", place: "top_of_spot" }, headers: @headers

    assert_response :success
    assert session.reload.spot?
    assert_equal 1000, session.precedence
  end

  test "the class write goes through Sessions::UpdateSchedulingClass, with the start deferred to the door" do
    session = waiting_spot_session
    calls = []
    real_call = Sessions::UpdateSchedulingClass.method(:call)
    spy = lambda do |**kwargs|
      calls << kwargs
      real_call.call(**kwargs)
    end

    Sessions::UpdateSchedulingClass.stub(:call, spy) do
      patch "/api/v1/sessions/#{session.id}", params: { scheduling_class: "priority", goal: "Ship it" }, headers: @headers
    end

    assert_response :success
    assert_equal 1, calls.size
    assert_equal :rest, calls.first[:actor]
    assert_equal false, calls.first[:start]
    assert_equal "started", JSON.parse(response.body)["start"]["outcome"]
    assert_equal "Ship it", session.reload.goal
  end

  # The class and the PATCH's other columns are one save, so the after_commit
  # callbacks keyed on those columns still see them — here the replacement
  # back-reference that `custom_metadata` drives.
  test "a class change alongside custom_metadata keeps that column's after-commit work" do
    replaced = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", status: :needs_input)
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", status: :needs_input,
      scheduling_class: SessionGenesis::PRIORITY)

    patch "/api/v1/sessions/#{session.id}",
      params: { scheduling_class: "spot", custom_metadata: { Session::REPLACES_SESSION_KEY => replaced.id.to_s } },
      headers: @headers, as: :json

    assert_response :success
    assert session.reload.spot?
    assert_equal replaced.id.to_s, replaced.reload.custom_metadata[Session::REPLACED_BY_SESSION_KEY].to_s
  end

  test "an unknown class refuses the whole PATCH, rename included" do
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", title: "Before",
      genesis: SessionGenesis::WEB_UI)

    patch "/api/v1/sessions/#{session.id}", params: { title: "After", scheduling_class: "whenever" }, headers: @headers

    assert_response :unprocessable_entity
    assert_includes response.body, "Scheduling class whenever is not a known scheduling class"
    session.reload
    assert_equal "Before", session.title
    assert_nil session.scheduling_class
    assert_empty session.logs.where("content LIKE ?", "Scheduling class%")
  end

  test "an unchanged class and rank write no log row" do
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", status: :needs_input,
      scheduling_class: SessionGenesis::SPOT, precedence: 5)

    assert_no_difference -> { session.logs.count } do
      patch "/api/v1/sessions/#{session.id}", params: { scheduling_class: "spot", precedence: 5 }, headers: @headers
    end
    assert_response :success
  end

  private

  # `status: :waiting` is the initial state and so is redundant, but the promote
  # branch turns on it — spelling it out is what makes these tests readable.
  def waiting_spot_session(session_id: nil)
    Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "x",
      genesis: SessionGenesis::GITHUB_ISSUE, status: :waiting, session_id: session_id
    )
  end
end
