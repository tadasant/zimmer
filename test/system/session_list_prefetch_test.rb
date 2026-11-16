require "application_system_test_case"

# The dashboard prefetches each row's drawer body into the browser's HTTP cache,
# so that clicking View is answered from the cache; the body shown that way then
# records the view itself. The prose is in
# docs/src/content/docs/sessions/lifecycle.md, "The dashboard prefetches what
# View opens".
class SessionListPrefetchTest < ApplicationSystemTestCase
  setup do
    @session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Prefetch me",
      title: "Prefetched session",
      status: :needs_input
    )
    @notification = Notification.create!(session: @session, notification_type: "needs_input", read: false, stale: false)
    @drawer_path = "/sessions/#{@session.to_param}/drawer"
  end

  test "View opens the drawer from the prefetched copy, and opening it records the view" do
    visit root_url(every_status_params(view: SessionsController::VIEW_MODE_CREATED_DESC))
    assert_selector "a[aria-label='View session #{@session.id}'][data-session-prefetch-target='link']"

    # The row's drawer body was fetched in the background, before any click...
    assert wait_for { drawer_fetches.any? }, "the dashboard should prefetch the row's drawer url"
    # ...and fetching it was not a view.
    assert_not @notification.reload.read?, "a prefetch must not mark the session's notifications read"

    find("a[aria-label='View session #{@session.id}']").click
    assert_selector "turbo-frame#session_detail [data-current-session-id='#{@session.id}']"

    # The frame's own load was answered from the HTTP cache: nothing came over
    # the wire for it. (The first fetch is the prefetch itself; a later one with
    # bytes on the wire is the activation request.)
    assert wait_for { drawer_fetches.drop(1).any? { |entry| entry["transferSize"].zero? } },
      "the click should be served from the prefetched copy, got #{drawer_fetches.inspect}"

    # Shown for real, the body re-requests itself, which is the view.
    assert wait_for { @notification.reload.read? }, "opening the prefetched drawer should mark notifications read"
    assert_no_selector "[data-controller='session-activation']", visible: :all
  end

  private

  def drawer_fetches
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource")
        .filter((entry) => new URL(entry.name).pathname === #{@drawer_path.to_json})
        .map((entry) => ({ transferSize: entry.transferSize }))
    JS
  end

  def wait_for(seconds: 10)
    deadline = Time.current + seconds
    loop do
      return true if yield
      return false if Time.current > deadline

      sleep 0.1
    end
  end
end
