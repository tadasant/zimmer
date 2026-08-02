require "test_helper"

# The Human Timeline on the REST surface.
#
# A sibling of `session`, not a key inside it: `session` means one shape on every
# response that carries it, and the timeline costs a query per ancestor, which
# the index would pay once per card. On show it is unconditional, so an empty
# array means "no human authored anything here" rather than "you didn't ask".
class Api::V1::SessionsControllerHumanTimelineTest < ActionDispatch::IntegrationTest
  setup do
    @api_key = "test_api_key_12345"
    ENV["API_KEYS"] = @api_key
    @headers = { "X-API-Key" => @api_key }
    @session = sessions(:running)
  end

  teardown { ENV.delete("API_KEYS") }

  def add_event(session, content:, author: "tadasant", channel: TimelineEvent::WEB_UI, at: Time.current)
    session.timeline_events.create!(
      event_type: TimelineEvent::HUMAN_MESSAGE,
      author: author,
      channel: channel,
      content: content,
      occurred_at: at,
      provenance: { "entry_point" => "web_ui.follow_up" }
    )
  end

  test "show carries an empty human_timeline when nothing was human-authored" do
    get "/api/v1/sessions/#{@session.id}", headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert json.key?("human_timeline"), "human_timeline must always be present on show"
    assert_empty json["human_timeline"]
    refute json["session"].key?("human_timeline"), "`session` must keep one shape across the API"
  end

  test "show renders a live human message with its full provenance" do
    add_event(@session, content: "Refactor the billing service", at: Time.utc(2026, 8, 2, 4, 5, 6))

    get "/api/v1/sessions/#{@session.id}", headers: @headers

    assert_response :success
    entry = JSON.parse(response.body)["human_timeline"].first
    assert_equal "human_message", entry["event_type"]
    assert_equal "live", entry["origin"]
    assert_equal "tadasant", entry["author"]
    assert_equal "Tadas", entry["author_display_name"]
    assert_equal "web_ui", entry["channel"]
    assert_equal "Zimmer web UI", entry["provenance"]
    assert_equal "web_ui.follow_up", entry["entry_point"]
    assert_equal "Refactor the billing service", entry["content"]
    assert_equal "2026-08-02T04:05:06Z", entry["occurred_at"]
  end

  test "show marks an inherited message and names its source session" do
    parent = Session.create!(
      agent_runtime: "claude_code",
      prompt: "route this",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
    @session.update!(parent_session_id: parent.id)
    add_event(parent, content: "original intent", at: 1.hour.ago)

    get "/api/v1/sessions/#{@session.id}", headers: @headers

    entry = JSON.parse(response.body)["human_timeline"].first
    assert_equal "inherited", entry["origin"]
    assert_equal parent.id, entry["source_session_id"]
    assert_includes entry["provenance"], "inherited from session ##{parent.id}"
  end

  test "index does not carry the timeline" do
    add_event(@session, content: "something")

    get "/api/v1/sessions", headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    refute json.key?("human_timeline"), "index must stay cheap — no per-card timeline query"
    json["sessions"].each do |s|
      refute s.key?("human_timeline"), "index must stay cheap — no per-card timeline query"
    end
  end
end
