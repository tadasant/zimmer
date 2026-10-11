# frozen_string_literal: true

require "test_helper"

# The dashboard's board views and the Ranked view's two writes, on the REST
# surface: `view=` on the index, `start_now`, and `reorder_precedence`. Each one
# answers what the web UI's own control does, from the same service.
class Api::V1::SessionsBoardViewsTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
    Session.delete_all
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  def make(title, created:, precedence: 0, scheduling_class: "spot", touched: nil, status: :needs_input)
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", title: title,
      scheduling_class: scheduling_class, precedence: precedence, status: status)
    session.update_columns(created_at: created)
    session.update_columns(metadata: session.metadata.merge("last_user_activity_at" => touched.iso8601)) if touched
    session
  end

  def ids_for(view)
    get "/api/v1/sessions", params: { view: view, per_page: 100 }, headers: @headers
    assert_response :success
    JSON.parse(response.body)["sessions"].map { |s| s["id"] }
  end

  test "view=last_touched orders by the last time a person acted, falling back to created" do
    old_but_touched = make("old", created: 3.days.ago, touched: 1.minute.ago)
    newest = make("new", created: 1.hour.ago)
    middle = make("mid", created: 1.day.ago)

    assert_equal [ old_but_touched.id, newest.id, middle.id ], ids_for("last_touched")
    assert_equal [ newest.id, middle.id, old_but_touched.id ], ids_for(nil), "the default is still newest created first"
  end

  test "view=user and view=ranked are Sessions::UserView: priority, then precedence, then oldest" do
    spot_low = make("spot low", created: 1.hour.ago, precedence: 1)
    spot_high_old = make("spot high old", created: 2.days.ago, precedence: 9)
    spot_high_new = make("spot high new", created: 1.day.ago, precedence: 9)
    priority = make("priority", created: 1.minute.ago, scheduling_class: "priority")

    expected = [ priority.id, spot_high_old.id, spot_high_new.id, spot_low.id ]
    assert_equal expected, ids_for("user")
    assert_equal expected, ids_for("ranked")

    json = JSON.parse(response.body)
    assert_equal 1, json["pagination"]["total_pages"]
    assert_equal false, json["truncated"]
  end

  test "view=user honours the filters the index already applies" do
    make("waiting", created: 1.hour.ago, status: :waiting)
    asked = make("asked", created: 2.hours.ago)

    get "/api/v1/sessions", params: { view: "user", status: "needs_input" }, headers: @headers
    assert_equal [ asked.id ], JSON.parse(response.body)["sessions"].map { |s| s["id"] }
  end

  test "start_now refuses a session with no turn queued, naming what to do instead" do
    session = make("ran before", created: 1.hour.ago, status: :waiting)
    session.update_columns(session_id: "abc-123")

    post "/api/v1/sessions/#{session.id}/start_now", headers: @headers

    assert_response :unprocessable_entity
    assert_match(/follow-up, or restart it/, JSON.parse(response.body)["message"])
  end

  test "start_now on a session that never ran starts its first turn" do
    session = make("fresh", created: 1.minute.ago, status: :waiting)

    post "/api/v1/sessions/#{session.id}/start_now", headers: @headers

    assert_response :success, response.body
    json = JSON.parse(response.body)
    assert_equal "started", json["outcome"]
    assert_equal session.id, json["session"]["id"]
  end

  test "reorder_precedence places a session between the rows it was dropped between" do
    top = make("top", created: 3.hours.ago, precedence: 30)
    bottom = make("bottom", created: 2.hours.ago, precedence: 10)
    moved = make("moved", created: 1.hour.ago, precedence: 0)

    patch "/api/v1/sessions/#{moved.id}/reorder_precedence", params: { above_id: top.id, below_id: bottom.id }, headers: @headers

    assert_response :success, response.body
    json = JSON.parse(response.body)
    precedence = json["session"]["precedence"]
    assert_operator precedence, :<, 30
    assert_operator precedence, :>, 10
    assert_includes json["changes"].map { |c| c["id"] }, moved.id
    assert_equal [ top.id, moved.id, bottom.id ], ids_for("ranked")
  end

  test "reorder_precedence answers a refusal with the reason" do
    session = make("alone", created: 1.hour.ago)

    patch "/api/v1/sessions/#{session.id}/reorder_precedence", params: { above_id: session.id }, headers: @headers

    assert_response :unprocessable_entity
    assert_match(/itself/, JSON.parse(response.body)["message"])
  end
end
