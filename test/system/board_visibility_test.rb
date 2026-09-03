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

    visit root_path
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
end
