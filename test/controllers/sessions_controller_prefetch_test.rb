# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The dashboard prefetches every row's session detail into the browser's HTTP
# cache (session_prefetch_controller.js). These pin the server's half of that
# contract: a prefetch is cacheable for a short while, records nothing, and
# carries the marker that makes the page record the view once it is shown; a
# request a human made is none of those things.
class SessionsControllerPrefetchTest < ActionDispatch::IntegrationTest
  PREFETCH = { "Accept" => "text/html, application/xhtml+xml", "X-Sec-Purpose" => "prefetch" }.freeze
  ACTIVATION_MARKER = 'data-controller="session-activation"'

  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    BroadcastService.any_instance.stubs(:notification_badge)

    @session = sessions(:active_session)
    @session.notifications.delete_all
    @session.update_column(:metadata, (@session.metadata || {}).merge("last_user_activity_at" => 2.days.ago.iso8601))
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  test "a prefetch of the drawer is reusable for a short while, keyed on Turbo-Frame" do
    get drawer_session_path(@session), headers: PREFETCH.merge("Turbo-Frame" => "session_detail")

    assert_response :success
    assert_equal "max-age=#{SessionsController::PREFETCH_MAX_AGE.to_i}, private", response.headers["Cache-Control"]
    assert_equal "Turbo-Frame", response.headers["Vary"],
      "varying on Accept would make a navigation miss what a fetch() prefetched"
  end

  test "a prefetch of the full page is reusable too, so a new tab or a phone's visit can use it" do
    get session_path(@session), headers: PREFETCH

    assert_response :success
    assert_equal "max-age=#{SessionsController::PREFETCH_MAX_AGE.to_i}, private", response.headers["Cache-Control"]
    assert_equal "Turbo-Frame", response.headers["Vary"]
  end

  test "a prefetch carries the activation marker, pointing back at the URL it answered" do
    get drawer_session_path(@session), headers: PREFETCH.merge("Turbo-Frame" => "session_detail")

    marker = css_select("[data-controller='session-activation']").first
    assert marker, "a prefetched body must be able to record its own view once shown"
    assert_equal drawer_session_path(@session), marker["data-session-activation-url-value"]
    assert_equal "session_detail", marker["data-session-activation-frame-value"]
    assert marker.attribute("hidden")

    get session_path(@session), headers: PREFETCH
    marker = css_select("[data-controller='session-activation']").first
    assert_equal session_path(@session), marker["data-session-activation-url-value"]
    assert_nil marker["data-session-activation-frame-value"], "a page url is loaded without a frame header"
  end

  test "a prefetch records nothing: notifications stay unread and the view is not counted" do
    notification = Notification.create!(session: @session, notification_type: "needs_input", read: false, stale: false)
    before = @session.reload.last_user_activity_at

    get drawer_session_path(@session), headers: PREFETCH.merge("Turbo-Frame" => "session_detail")
    get session_path(@session), headers: PREFETCH

    assert_not notification.reload.read?, "prefetching a list must not mark its sessions read"
    assert_equal before.to_i, @session.reload.last_user_activity_at.to_i
  end

  test "the activation request — an ordinary GET of the same URL — records the view" do
    notification = Notification.create!(session: @session, notification_type: "needs_input", read: false, stale: false)

    get drawer_session_path(@session), headers: { "Accept" => "text/html, application/xhtml+xml", "Turbo-Frame" => "session_detail" }

    assert_response :success
    assert notification.reload.read?
    assert_not_includes response.body, ACTIVATION_MARKER, "only a prefetched body needs activating"
  end

  test "a request a human made is never cacheable" do
    get session_path(@session), headers: { "Accept" => "text/html, application/xhtml+xml" }

    assert_response :success
    assert_includes response.headers["Cache-Control"], "max-age=0"
    assert_includes response.headers["Cache-Control"], "private"
    assert_not_includes response.body, ACTIVATION_MARKER
  end

  test "the dashboard's session links are prefetch targets carrying the drawer url" do
    get dashboard_board_path, headers: { "Turbo-Frame" => "sessions_board" }

    assert_response :success
    links = css_select("a[data-session-prefetch-target='link']")
    assert_predicate links, :any?, "the board's View links are what the prefetcher fetches"
    links.each do |link|
      assert_match %r{\A/sessions/[^/]+/drawer\z}, link["data-session-drawer-url"]
      assert_equal "false", link["data-turbo-prefetch"]
    end
  end

  test "the detail render builds the agent-roots catalog once" do
    calls = 0
    original = AgentRootsConfig.method(:build_roots)
    AgentRootsConfig.stubs(:build_roots).with { calls += 1 }.returns(original.call)

    get drawer_session_path(@session), headers: { "Accept" => "text/html, application/xhtml+xml" }

    assert_response :success
    assert_equal 1, calls
  end
end
