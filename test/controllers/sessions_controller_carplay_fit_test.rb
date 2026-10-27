require "test_helper"
require "mocha/minitest"

# The dashboard half of CarPlay fit: the PATCH the control drives, the chip on
# the User view row, and the Filters section's radios. A person's write from
# here is a `human` mark, the one that outranks every other writer.
class SessionsControllerCarplayFitTest < ActionDispatch::IntegrationTest
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Session.any_instance.stubs(:broadcast_remove_from_sessions_index)
    Log.any_instance.stubs(:broadcast_append_to_timeline)

    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all
    AppSetting.delete_all
  end

  def make_session(title: "A session", **attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      title: title,
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: lines(3)
    }.merge(attrs))
  end

  # `transcript_line_count` is derived from the transcript, so a session that is
  # "at line N" needs N lines of one.
  def lines(n)
    n.times.map { |i| JSON.generate({ "type" => "user", "message" => { "role" => "user", "content" => "m#{i}" } }) }.join("\n") + "\n"
  end

  test "marks a session as laptop-only as a human and answers with the mark" do
    session = make_session

    patch update_carplay_fit_session_path(session),
      params: { carplay_fit: "laptop_only", carplay_fit_reason: "credential" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert body["applied"]
    assert_equal "laptop_only", body["carplay_fit"]
    assert_equal "human", body["carplay_fit_source"]
    session.reload
    assert_equal "laptop_only", session.carplay_fit
    assert_equal "human", session.carplay_fit_source
    assert_equal 3, session.carplay_fit_line_count
  end

  test "the HTML form redirects back with a notice, and clear removes the mark" do
    session = make_session(carplay_fit: "carplay_ok", carplay_fit_source: "auto", carplay_fit_line_count: 3)

    patch update_carplay_fit_session_path(session), params: { carplay_fit: "clear" },
      headers: { "Referer" => session_path(session) }

    assert_redirected_to session_path(session)
    assert_match(/CarPlay fit cleared/, flash[:notice])
    assert_nil session.reload.carplay_fit
  end

  test "a value off the list is refused" do
    session = make_session

    patch update_carplay_fit_session_path(session),
      params: { carplay_fit: "maybe" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

    assert_response :unprocessable_entity
    assert_nil session.reload.carplay_fit
  end

  test "the session page offers the control and the User view row shows the chip" do
    session = make_session(carplay_fit: "laptop_only", carplay_fit_reason: "credential", carplay_fit_source: "auto",
                           carplay_fit_line_count: 3, carplay_fit_set_at: Time.current)

    get session_path(session)
    assert_response :success
    assert_select "form[action='#{update_carplay_fit_session_path(session)}']" do
      assert_select "select[name='carplay_fit_reason'] option[value='credential'][selected]"
      assert_select "button[name='carplay_fit'][value='carplay_ok']"
      assert_select "button[name='carplay_fit'][value='laptop_only']"
      assert_select "button[name='carplay_fit'][value='clear']"
    end

    get dashboard_board_path, params: { view: "user" }
    assert_response :success
    assert_select "[data-carplay-fit='laptop_only']", text: /Laptop only · a credential/
  end

  test "the Filters form narrows the board on CarPlay fit and remembers the choice" do
    laptop = make_session(title: "needs the mac", carplay_fit: "laptop_only", carplay_fit_source: "auto", carplay_fit_line_count: 3)
    ok = make_session(title: "say yes", carplay_fit: "carplay_ok", carplay_fit_source: "auto", carplay_fit_line_count: 3)
    untagged = make_session(title: "nobody judged")

    get dashboard_board_path, params: { view: "user", filters: "1", status: [ "needs_input" ], carplay_fit: "not_laptop_only" }
    assert_response :success
    assert_select "#user_view_row_#{ok.id}"
    assert_select "#user_view_row_#{untagged.id}"
    assert_select "#user_view_row_#{laptop.id}", count: 0
    get root_path
    assert_select "input#carplay-fit-filter-not-laptop-only[checked]"

    # Remembered in the cookie, like the other filters.
    get dashboard_board_path, params: { view: "user" }
    assert_select "#user_view_row_#{laptop.id}", count: 0

    # And the default is every row.
    get dashboard_board_path, params: { view: "user", filters: "1", status: [ "needs_input" ], carplay_fit: "" }
    assert_select "#user_view_row_#{laptop.id}"
    get root_path
    assert_select "input#carplay-fit-filter-all[checked]"
  end
end
