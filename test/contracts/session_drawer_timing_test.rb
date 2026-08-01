# frozen_string_literal: true

require "test_helper"

# The session drawer's slide duration must exist in exactly one place.
#
# It used to exist in two: `transition-transform duration-300` on the panel, and
# a bare `setTimeout(..., 300)` in session_drawer_controller.js, with nothing
# linking them. Either could be changed alone and the pair would drift silently —
# the timer firing early (the drawer torn down mid-slide) or late — with no test
# to notice. That is half of issue #180; the other half is what a click landing
# during an un-gated slide does, which the system suite covers.
#
# The arrangement that replaced it: CSS declares the duration, and the controller
# reads it back off the panel via `getComputedStyle(...).transitionDuration`, so
# every timer is derived from the one number the browser is actually using. These
# assertions pin that arrangement in place. They are deliberately source-level —
# the drift they exist to catch is a source edit, and it can be caught without
# booting a browser.
class SessionDrawerTimingTest < ActiveSupport::TestCase
  DASHBOARD_VIEW = Rails.root.join("app/views/sessions/index.html.erb")
  DRAWER_CONTROLLER = Rails.root.join("app/javascript/controllers/session_drawer_controller.js")
  TAILWIND_CSS = Rails.root.join("app/assets/tailwind/application.css")

  test "the drawer panel declares its slide duration in CSS" do
    panel_tag = DASHBOARD_VIEW.read[/<div data-session-drawer-target="panel".*?>/m]

    assert panel_tag, "Could not find the session drawer panel element in #{DASHBOARD_VIEW}"
    assert_includes panel_tag, "transition-transform",
      "The panel must declare its own transition — the controller reads the duration back off it."
    assert_includes panel_tag, "duration-300",
      "The panel's slide duration lives here and only here."
  end

  test "every drawer timer is driven by the panel's own transition duration" do
    source = DRAWER_CONTROLLER.read

    timers = source.scan(/setTimeout\(/).length
    derived_delays = source.scan(/,\s*this\.transitionMs\s*\)/).length

    assert_operator timers, :>, 0, "Expected the drawer controller to schedule at least one timer."
    assert_equal timers, derived_delays,
      "Every setTimeout in the drawer controller must take `this.transitionMs` as its delay. " \
      "A literal duration is a second copy of the CSS `duration-300`, free to drift from it (#180)."
  end

  test "the drawer controller reads its duration from the rendered panel" do
    source = DRAWER_CONTROLLER.read

    assert_includes source, "getComputedStyle(this.panelTarget)",
      "transitionMs must read the panel's computed style, not a hardcoded value."
    assert_includes source, "transitionDuration",
      "transitionMs must derive from the panel's transition-duration."
  end

  test "the settle gate does not depend on transitionend alone" do
    source = DRAWER_CONTROLLER.read

    assert_includes source, "transitionend",
      "The gate should lift as soon as the slide really ends."
    assert_match(/setTimeout\(this\.boundSettle, this\.transitionMs\)/, source,
      "The gate also needs a timer: a zero-duration transition (prefers-reduced-motion, or the " \
      "system suite's disabled animations) never fires transitionend, and a transitionend-only " \
      "gate would leave those users a permanently inert drawer.")
  end

  test "prefers-reduced-motion zeroes the panel transition" do
    css = TAILWIND_CSS.read
    rule = css[/@media \(prefers-reduced-motion: reduce\).*?\n\}/m]

    assert rule, "Expected a prefers-reduced-motion block in #{TAILWIND_CSS}"
    assert_includes rule, '[data-session-drawer-target="panel"]',
      "The drawer panel must be covered by the reduced-motion rule."
    assert_includes rule, "transition: none",
      "Reduced motion must remove the slide, which also collapses the inert window to one tick."
  end
end
