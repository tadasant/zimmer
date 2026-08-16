require "application_system_test_case"

# The dashboard's mutating actions answer with Turbo Streams rather than a
# redirect, and the session page re-subscribes its cable instead of reloading
# itself. Both are things only a browser can prove, so they live here.
#
# The "no full page load" assertions work by stamping a value on `window` before
# the interaction. A Turbo Stream keeps the same window object; a native form
# submit or a <meta http-equiv="refresh"> tears the document down and takes the
# stamp with it.
class DashboardTurboActionsTest < ApplicationSystemTestCase
  # Screenshots land next to the failure screenshots Rails writes, so CI's
  # artifact upload picks them up and a PR can show what changed.
  SCREENSHOT_DIR = Rails.root.join("tmp", "capybara")

  test "trashing a session streams the card away and offers Undo in the flash" do
    session = sessions(:failed)

    visit root_path(every_status_params)
    assert_selector "turbo-frame#session_#{session.id}"
    stamp_window

    within "turbo-frame#session_#{session.id}" do
      click_on "Trash"
    end

    # The toast is the regression under test: before the flash container had an
    # id, the archive stream had nowhere to render it and Undo never appeared.
    assert_selector "#flash", text: "Session moved to trash."
    assert_selector "#flash", text: "Undo"
    assert_no_selector "turbo-frame#session_#{session.id}"
    assert_equal "kept", window_stamp, "trashing a session should not reload the page"

    capture("undo-toast")
  end

  # The detail header's Trash button is the one the dashboard's session drawer
  # puts in front of you, and it archives through archive-countdown rather than
  # through the card's link. A native `form.submit()` fires no `submit` event,
  # so Turbo never sees the submission: the browser POSTs for real, #archive
  # answers on its format.html branch, and the redirect reloads the dashboard
  # from the top, discarding the scroll offset the drawer was opened over. The
  # window stamp is what separates the two — a stream keeps the document, a
  # reload takes it and the stamp with it.
  test "trashing from the session drawer streams in place instead of reloading the dashboard" do
    session = sessions(:failed)

    # The header actions this test drives sit in a `hidden md:block` wrapper, so
    # the Trash button is display:none below Tailwind's md breakpoint. Other
    # tests in the suite resize to phone widths and share the browser, so pin a
    # desktop width rather than inheriting whatever the last one left behind.
    page.driver.browser.manage.window.resize_to(1400, 900)

    visit root_path
    assert_selector "turbo-frame#session_#{session.id}"
    stamp_window

    within "turbo-frame#session_#{session.id}" do
      click_on "View"
    end
    # The drawer lazy-loads the detail view into its frame; the Trash button
    # only exists once that frame has landed.
    assert_selector "[data-controller~='archive-countdown'] button", text: "Trash"

    find("[data-controller~='archive-countdown'] button", text: "Trash").click

    assert_selector "#flash", text: "Session moved to trash."
    assert_selector "#flash", text: "Undo"
    assert_no_selector "turbo-frame#session_#{session.id}"
    assert_equal "kept", window_stamp, "trashing from the drawer should not reload the page"

    capture("drawer-trash-in-place")
  end

  test "Undo puts the trashed card back without leaving the dashboard" do
    session = sessions(:failed)

    visit root_path(every_status_params)
    assert_selector "turbo-frame#session_#{session.id}"

    within "turbo-frame#session_#{session.id}" do
      click_on "Trash"
    end
    assert_selector "#flash", text: "Undo"
    stamp_window

    within "#flash" do
      click_on "Undo"
    end

    assert_selector "turbo-frame#session_#{session.id}"
    assert_selector "#flash", text: "Session restored from trash."
    assert_equal "kept", window_stamp, "Undo should not navigate away from the dashboard"
    assert_not session.reload.archived?

    capture("undo-restored")
  end

  test "Refresh all reports into the flash target without reloading the dashboard" do
    # Leaving nothing to refresh keeps the click off the restart/continue paths
    # that reach for real processes; the response shape is what is under test.
    Session.where.not(status: :archived).update_all(status: :archived)

    visit root_path
    stamp_window

    # Refresh-all renders twice (mobile menu + sidebar); drive the visible one.
    find("form[action='#{refresh_all_sessions_path}'] button", match: :first).click

    assert_selector "#flash", text: "No non-archived sessions to refresh"
    assert_equal "kept", window_stamp, "Refresh all should not reload the page"

    capture("refresh-all-flash")
  end

  test "the recovery banner no longer schedules a page refresh" do
    session = sessions(:running)
    session.logs.create!(content: "Recovery job enqueued for session", level: "info")

    visit session_path(session)

    # The banner still tells the user what happened...
    assert_text "Session connection recovered. Live updates have been restored."
    # ...but nothing on the page reloads it behind their back.
    assert_no_selector "meta[http-equiv='refresh']", visible: :all
    assert_selector "[data-controller~='cable-reconnect']", visible: :all

    capture("recovery-banner")
  end

  test "a dropped subscription is re-subscribed from its connection state" do
    session = sessions(:running)

    visit session_path(session)
    wait_for_turbo_streams_connected(timeout: 10)
    stamp_window

    # Simulate the silent death the meta refresh existed to paper over: the
    # element is still in the DOM but its subscription is gone.
    page.execute_script(<<~JS)
      document.querySelectorAll("turbo-cable-stream-source").forEach((source) => {
        source.removeAttribute("connected")
      })
    JS

    # The controller notices the missing `connected` attribute and re-subscribes,
    # which restores it — with no navigation and no reload.
    wait_for_turbo_streams_connected(timeout: 15)
    assert_equal "kept", window_stamp, "reconnecting must not reload the page"
  end

  private

  def capture(name)
    FileUtils.mkdir_p(SCREENSHOT_DIR)
    # The session page restores its scroll position on load, which would frame
    # the shot below the thing the test just asserted.
    page.execute_script("window.scrollTo(0, 0)")
    page.save_screenshot(SCREENSHOT_DIR.join("proof-#{name}.png"))
  end

  def stamp_window
    page.execute_script("window.__zimmerPageLoadStamp = 'kept'")
  end

  def window_stamp
    page.evaluate_script("window.__zimmerPageLoadStamp")
  end
end
