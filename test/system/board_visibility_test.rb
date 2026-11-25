require "application_system_test_case"

# The board-visibility panel at a phone width.
#
# This is the coverage the deleted PauseUntilTest carried, pointed at the control
# that inherited its shape. The panel is the one thing here that can only break in
# a browser: it opens inline inside an already-absolute overflow menu on a card and
# as a popover on the detail header, and the failure mode is silent — a panel that
# renders past the right edge of a 375px viewport is a control nobody can press,
# and only the person reading Zimmer on their phone finds out.
#
# `overflow_menu_controller.js` says so itself, and cites this hazard as the reason
# it refuses to nest a popover inside its menu.
class BoardVisibilityTest < ApplicationSystemTestCase
  MOBILE = [ 375, 812 ].freeze

  def create_session(**overrides)
    Session.create!({
      title: "Waiting on the deploy",
      prompt: "Ship the thing.",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    }.merge(overrides))
  end

  # Left edge, how far the right edge runs past the viewport, and whether opening
  # the panel made the document itself scroll sideways. All three have to hold: a
  # panel can be on screen and still push the page wider than the phone.
  def panel_geometry
    page.evaluate_script(<<~JS)
      (function () {
        const p = document.querySelector("[data-visibility-target='panel']:not(.hidden)");
        if (!p) return null;
        const b = p.getBoundingClientRect();
        return [Math.round(b.left), Math.round(b.right - document.documentElement.clientWidth),
                document.documentElement.scrollWidth - document.documentElement.clientWidth];
      })()
    JS
  end

  def assert_panel_on_screen(label)
    geometry = panel_geometry
    assert geometry, "no open #{label} panel to measure"
    left, past_right, doc_overflow = geometry

    assert left >= 0, "the #{label} panel starts #{-left}px off the left edge at #{MOBILE.first}px"
    assert past_right <= 1, "the #{label} panel runs #{past_right}px past the right edge at #{MOBILE.first}px"
    assert doc_overflow <= 0, "opening the #{label} panel makes the page scroll sideways by #{doc_overflow}px"
  end

  test "the card menu's snooze panel opens fully on screen at a phone width" do
    session = create_session
    page.driver.browser.manage.window.resize_to(*MOBILE)

    # The ⋮ menu is on the session card, which the flat sort views render.
    visit root_path(view: SessionsController::VIEW_MODE_CREATED_DESC)
    assert_text "Waiting on the deploy"

    find("##{ActionView::RecordIdentifier.dom_id(session)} button[aria-label='More actions for session #{session.id}']").click
    click_on "Snooze until…"
    assert_text "Later today"

    assert_panel_on_screen("card menu snooze")
  ensure
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  test "the mobile sheet's snooze panel opens fully on screen at a phone width" do
    session = create_session
    page.driver.browser.manage.window.resize_to(*MOBILE)

    visit session_path(session)
    # A phone gets the joystick's bottom sheet, not the `hidden md:block` header.
    # The sheet is revealed directly rather than by driving the press-and-hold
    # gesture: what is under test is the panel this partial renders, and the
    # gesture has its own coverage.
    assert_selector "[data-joystick-menu-target='sheet']", visible: :all
    page.execute_script(<<~JS)
      const sheet = document.querySelector("[data-joystick-menu-target='sheet']");
      sheet.classList.remove("hidden", "translate-y-full", "opacity-0");
    JS
    click_on "Snooze until…"
    assert_text "Later today"

    assert_panel_on_screen("bottom sheet snooze")
  ensure
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  # A board card's Backlog lives in its ⋯ menu, under Snooze.
  def backlog_from_menu(session)
    find("#board_v2_row_#{session.id} button[aria-label='More actions for session #{session.id}']").click
    within("#board_v2_row_#{session.id}") do
      click_on "Snooze until…"
      click_on "Move to backlog"
    end
  end

  # The count is computed by /board and carried to the shell's Filters legend as a
  # <turbo-stream> inside the board frame, so only a browser shows it arriving.
  test "the Filters legend says how many sessions the loaded board is holding back" do
    create_session(title: "Still on the board")
    create_session(title: "Tucked away", visibility: SessionVisibility::HIDDEN)

    visit root_path(view: SessionsController::VIEW_MODE_BOARD_V2)

    assert_selector "#board_v2", text: "Still on the board"
    assert_selector "#off-board-count", text: "1 session tucked away"
    assert_no_selector "#board_v2", text: "Tucked away"
  end

  # A dashboard left open on another filter fetches its own board again whenever the
  # categories change. That must not bring its filter back for anyone who has since
  # asked for the default board.
  test "an All board left open in another tab does not undo Reset filters" do
    create_session(title: "Still on the board")
    create_session(title: "Tucked away", visibility: SessionVisibility::HIDDEN)
    create_session(title: "Snoozed for now", visibility: SessionVisibility::SNOOZED, snoozed_until: 2.days.from_now)
    create_session(title: "Some other month", visibility: SessionVisibility::BACKLOGGED)

    visit root_path(view: SessionsController::VIEW_MODE_BOARD_V2,
                    SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: "all")
    assert_selector "#board_v2", text: "Tucked away"

    within_window(open_new_window) do
      visit root_path(view: SessionsController::VIEW_MODE_BOARD_V2)
      assert_selector "#board_v2", text: "Tucked away"
      click_on "Reset filters"
      assert_on_default_board
    end

    # The open tab hears of the new category, so it has fetched its board again.
    BoardCategory.create!(name: "Arrived later")
    assert_selector "#board_v2", text: "Arrived later", wait: 8

    within_window(open_new_window) do
      visit root_path(view: SessionsController::VIEW_MODE_BOARD_V2)
      assert_on_default_board
      [ "Tucked away", "Snoozed for now", "Some other month" ].each { |title| assert_no_selector "#board_v2", text: title }
    end
  end

  test "hovering over a view does not choose it" do
    visit root_path(view: SessionsController::VIEW_MODE_BOARD_V2)
    within("[aria-label='Dashboard view mode']") { find_link("Ranked").hover }
    sleep 1 # Turbo prefetches 100ms into a hover; this is the request not being made.

    visit root_path
    assert_selector "[aria-label='Dashboard view mode'] [aria-pressed='true']", text: "Your board"
  end

  def assert_on_default_board
    assert_checked_field "visibility", with: SessionsController::VISIBILITY_ON_BOARD, visible: :all, wait: 8
    wait_for_dashboard_board
    assert_selector "#board_v2", text: "Still on the board"
  end

  # The removal decision is the browser's: visibility_controller.js takes a row off
  # the page when the board on screen does not show the visibility it is moving to.
  test "moving a row to the backlog takes it off the default board and counts it" do
    create_session(title: "Still on the board")
    create_session(title: "Low priority, half done")

    visit root_path(view: SessionsController::VIEW_MODE_BOARD_V2)
    backlog_from_menu(Session.find_by!(title: "Low priority, half done"))

    assert_no_selector "#board_v2", text: "Low priority, half done"
    assert_selector "#board_v2", text: "Still on the board"
    assert_equal SessionVisibility::BACKLOGGED, Session.find_by!(title: "Low priority, half done").visibility

    visit root_path(view: SessionsController::VIEW_MODE_BOARD_V2)
    assert_selector "#off-board-count", text: "1 backlogged"
  end

  test "on the All board a backlogged row stays and is redrawn with its badge" do
    create_session(title: "Low priority, half done")

    visit root_path(view: SessionsController::VIEW_MODE_BOARD_V2,
                    SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: "all")
    # The page visits itself once the server agrees. Waited out, so the row is read
    # from the board that visit brought, and the test does not end with it in flight.
    page.execute_script("document.querySelector('#board_v2').dataset.beforeTheVisit = ''")
    backlog_from_menu(Session.find_by!(title: "Low priority, half done"))
    assert_no_selector "#board_v2[data-before-the-visit]", wait: 8
    wait_for_dashboard_board

    assert_selector "#board_v2 [id^='board_v2_row_']", text: /Low priority, half done.*Backlog/m
    assert_equal SessionVisibility::BACKLOGGED, Session.find_by!(title: "Low priority, half done").visibility
  end
end
