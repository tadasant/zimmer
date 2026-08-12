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
