# frozen_string_literal: true

require "test_helper"

# The session drawer's Turbo Frame must fetch a URL that no link on the page
# points at.
#
# This is the fix for a bug that had already been "fixed" three times and kept
# coming back: the drawer intermittently rendered Turbo's "Content missing"
# placeholder instead of the session. /sessions/:id used to serve two
# structurally different bodies — the frameless full page, or the same body
# wrapped in <turbo-frame id="session_detail"> — chosen by the Turbo-Frame
# request header. Every earlier mitigation aimed at HTTP caching (a `Vary:
# Turbo-Frame` header, `data-turbo-prefetch="false"` on individual links), and
# none of them could work, because the cache that actually caused it is not an
# HTTP cache: Turbo 8's LinkPrefetchObserver stores a hover-prefetched
# FetchRequest keyed ONLY by URL and splices it into any later GET fetch for the
# same URL — a Turbo Frame's own `src` load included — throwing away the frame's
# Turbo-Frame header with it. That substitution happens in browser memory and
# never touches the network, so no response header can reach it, and because the
# key is the URL alone, guarding one link never helped: any other <a> to the same
# session seeded the entry just as well.
#
# Disjoint URLs remove the collision itself rather than defending against it. The
# assertions below are source-level because the thing they protect is a source
# edit — someone "simplifying" the drawer back onto the link's own href would
# reintroduce the whole class in one line.
class SessionDrawerFrameUrlTest < ActiveSupport::TestCase
  DRAWER_CONTROLLER = Rails.root.join("app/javascript/controllers/session_drawer_controller.js")

  test "the drawer loads its own url, not the trigger link's href" do
    source = DRAWER_CONTROLLER.read

    assert_includes source, "event.currentTarget.dataset.sessionDrawerUrl",
      "The drawer's frame src must come from the trigger's data-session-drawer-url, " \
      "which points at a path no <a href> on the page uses."
    assert_no_match(/const url = event\.currentTarget\.href/, source,
      "Loading the trigger's own href into the frame puts the frame's fetch back on a URL " \
      "that links point at, so Turbo's URL-keyed prefetch cache can poison it again.")
  end

  test "the drawer variant is served by its own route" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Drawer route")

    assert_not_equal Rails.application.routes.url_helpers.session_path(session),
      Rails.application.routes.url_helpers.drawer_session_path(session),
      "The drawer and the full page must not share a URL — that shared key is the bug."
    assert_equal "sessions#drawer",
      Rails.application.routes.recognize_path(
        Rails.application.routes.url_helpers.drawer_session_path(session)
      ).values_at(:controller, :action).join("#")
  end
end
