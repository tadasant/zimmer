require "test_helper"
require "mocha/minitest"

# The REST half of CarPlay fit: PATCH /api/v1/sessions/:id/carplay_fit, the
# fields on the serialized session, and the OPTIONAL listing filter — unset by
# default for the reason the visibility one is.
class Api::V1::SessionsCarplayFitTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key

    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Log.any_instance.stubs(:broadcast_append_to_timeline)
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
      transcript: lines(5)
    }.merge(attrs))
  end

  # `transcript_line_count` is derived from the transcript, so a session that is
  # "at line N" needs N lines of one.
  def lines(n)
    n.times.map { |i| JSON.generate({ "type" => "user", "message" => { "role" => "user", "content" => "m#{i}" } }) }.join("\n") + "\n"
  end

  test "a serialized session carries the mark, its provenance and the resolved value" do
    session = make_session(carplay_fit: "laptop_only", carplay_fit_reason: "credential", carplay_fit_source: "auto",
                           carplay_fit_set_at: Time.current, carplay_fit_line_count: 5)

    get "/api/v1/sessions/#{session.id}", headers: @headers

    assert_response :success
    json = JSON.parse(response.body)["session"]
    assert_equal "laptop_only", json["carplay_fit"]
    assert_equal "laptop_only", json["effective_carplay_fit"]
    assert_equal "credential", json["carplay_fit_reason"]
    assert_equal "auto", json["carplay_fit_source"]
    assert_equal 5, json["carplay_fit_line_count"]
    assert_match(/Laptop only \(a credential\) · auto · current/, json["carplay_fit_summary"])

    session.update!(transcript: lines(9))
    get "/api/v1/sessions/#{session.id}", headers: @headers
    json = JSON.parse(response.body)["session"]
    assert_equal "laptop_only", json["carplay_fit"]
    assert_nil json["effective_carplay_fit"], "a stale mark resolves to nothing"
  end

  test "PATCH writes an assistant mark on an API key and reports it applied" do
    session = make_session

    patch "/api/v1/sessions/#{session.id}/carplay_fit",
      params: { carplay_fit: "carplay_ok", carplay_fit_reason: "decision" }.to_json,
      headers: @headers.merge("Content-Type" => "application/json")

    assert_response :success
    body = JSON.parse(response.body)
    assert body["carplay_fit_result"]["applied"]
    assert_equal "carplay_ok", body["session"]["carplay_fit"]
    assert_equal "assistant", body["session"]["carplay_fit_source"]
  end

  test "PATCH naming acting_session_id writes a session mark, and a standing human mark is kept" do
    session = make_session
    Sessions::SetCarplayFit.call(session: session, fit: "laptop_only", source: "human")

    patch "/api/v1/sessions/#{session.id}/carplay_fit",
      params: { carplay_fit: "carplay_ok", acting_session_id: session.id }.to_json,
      headers: @headers.merge("Content-Type" => "application/json")

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal false, body["carplay_fit_result"]["applied"]
    assert_match(/human mark outranks a session one/, body["carplay_fit_result"]["message"])
    assert_equal "laptop_only", session.reload.carplay_fit
  end

  test "PATCH with a value off the list is a 422 naming the valid ones" do
    session = make_session

    patch "/api/v1/sessions/#{session.id}/carplay_fit",
      params: { carplay_fit: "maybe" }.to_json,
      headers: @headers.merge("Content-Type" => "application/json")

    assert_response :unprocessable_entity
    assert_match(/carplay_ok, laptop_only/, response.body)
  end

  test "the listing is unfiltered by default and narrows on carplay_fit when asked" do
    ok = make_session(carplay_fit: "carplay_ok", carplay_fit_source: "auto", carplay_fit_line_count: 5)
    laptop = make_session(carplay_fit: "laptop_only", carplay_fit_source: "auto", carplay_fit_line_count: 5)
    untagged = make_session

    get "/api/v1/sessions", params: { status: "needs_input" }, headers: @headers
    ids = JSON.parse(response.body)["sessions"].map { |s| s["id"] }
    assert_includes ids, laptop.id

    get "/api/v1/sessions", params: { status: "needs_input", carplay_fit: "not_laptop_only" }, headers: @headers
    ids = JSON.parse(response.body)["sessions"].map { |s| s["id"] }
    assert_includes ids, ok.id
    assert_includes ids, untagged.id
    assert_not_includes ids, laptop.id

    get "/api/v1/sessions", params: { status: "needs_input", carplay_fit: "laptop_only" }, headers: @headers
    assert_equal [ laptop.id ], JSON.parse(response.body)["sessions"].map { |s| s["id"] }
  end
end
