require "application_system_test_case"

# The log-level filter is a server round trip: changing it re-renders the detail
# body with a `filter` param so the server can filter items before paginating
# them. The body renders at two different addresses — the full session page
# (/sessions/:id, the document itself) and the dashboard drawer's lazy frame
# (/sessions/:id/drawer) — so "re-render me at this level" has to address the
# right one, or the drawer navigates the dashboard and dismisses itself (#666).
#
# These tests pin both halves: the drawer re-filters its own frame, and the full
# page still navigates itself. The prose is in
# docs/src/content/docs/sessions/lifecycle.md, "The drawer loads its own URL".
class SessionDrawerLogFilterTest < ApplicationSystemTestCase
  # A log line is a "regular-log" item: the server renders it at `show-logs` and
  # `verbose`, and omits it at `minimal` (the default). So its presence is a
  # direct read of which filter the body was rendered with.
  LOG_LINE = "drawer log filter marker line".freeze

  setup do
    @session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Drawer log filter session",
      status: :running
    )
    @session.logs.create!(content: LOG_LINE, level: "info")
  end

  test "opening the drawer with a saved log level re-filters the drawer instead of navigating the dashboard" do
    visit root_url(every_status_params)
    dashboard_url = page.current_url

    # The reader has previously moved the log level off the default. This is the
    # state that made every subsequent drawer open dismiss itself.
    page.execute_script("localStorage.setItem('logLevelFilter', 'show-logs')")

    find("a[aria-label='View session #{@session.id}']").click

    # The frame re-fetched itself at the saved level. Waiting on the server-set
    # `selected` option (not merely on the frame's src, which is set the instant
    # the fetch starts) means the re-rendered body is actually in the DOM.
    assert_selector "turbo-frame#session_detail select#log-level-filter option[value='show-logs'][selected]",
                    visible: :all
    assert_selector "turbo-frame#session_detail[src*='filter=show-logs']", visible: :all

    # ...and it re-filtered for real: the log line is only rendered at show-logs.
    open_transcript_panel(wait: 5)
    within "turbo-frame#session_detail" do
      assert_text LOG_LINE
    end

    # The drawer is still open and the dashboard behind it never moved.
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='false']"
    assert_equal dashboard_url, page.current_url
  end

  test "changing the log level inside the drawer re-filters the drawer in place" do
    visit root_url(every_status_params)
    dashboard_url = page.current_url

    find("a[aria-label='View session #{@session.id}']").click
    assert_selector "turbo-frame#session_detail [data-current-session-id='#{@session.id}']"
    # No saved preference, so the drawer opens at the server default.
    assert_selector "turbo-frame#session_detail select#log-level-filter option[value='minimal'][selected]",
                    visible: :all

    within "turbo-frame#session_detail" do
      select "Show Logs", from: "log-level-filter"
    end

    assert_selector "turbo-frame#session_detail select#log-level-filter option[value='show-logs'][selected]",
                    visible: :all
    open_transcript_panel(wait: 5)
    within "turbo-frame#session_detail" do
      assert_text LOG_LINE
    end

    # The whole point: the drawer stayed open and the dashboard was not navigated.
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='false']"
    assert_equal dashboard_url, page.current_url
  end

  # Re-filtering in place is only in place if the reader is still looking at
  # something afterwards. The Transcript disclosure renders collapsed on every
  # ordinary load, so a re-render that does not say otherwise takes the
  # transcript the reader was filtering off the screen — the drawer stays open
  # and the level really did change, but nothing on screen shows it, which is
  # indistinguishable from a filter that did nothing.
  test "changing the log level with the transcript open leaves it open at the new level" do
    visit root_url(every_status_params)
    dashboard_url = page.current_url

    find("a[aria-label='View session #{@session.id}']").click
    assert_selector "turbo-frame#session_detail [data-current-session-id='#{@session.id}']"

    # The reader opens the transcript and is reading it, which is the state the
    # log level is worth changing from.
    open_transcript_panel(wait: 5)
    assert_selector "turbo-frame#session_detail details[data-controller~='transcript-panel'][open]"

    within "turbo-frame#session_detail" do
      select "Show Logs", from: "log-level-filter"
    end

    assert_selector "turbo-frame#session_detail select#log-level-filter option[value='show-logs'][selected]",
                    visible: :all

    # Still open, and showing the level that was just asked for — no second
    # click on the disclosure to see the result of the first one. Asserting the
    # frame's own `src` as well as the rendered state is what tells "the server
    # was asked for it open" apart from "the browser happened to keep it open".
    assert_selector "turbo-frame#session_detail[src*='transcript=open']", visible: :all
    assert_selector "turbo-frame#session_detail details[data-controller~='transcript-panel'][open]"
    within "turbo-frame#session_detail" do
      assert_text LOG_LINE
    end

    assert_selector "[data-session-drawer-target='panel'][aria-hidden='false']"
    assert_equal dashboard_url, page.current_url
  end

  # The state travels, it does not stick: a reader who never opened the
  # transcript is not handed one open by a filter change.
  test "changing the log level with the transcript closed leaves it closed" do
    visit root_url(every_status_params)

    find("a[aria-label='View session #{@session.id}']").click
    assert_selector "turbo-frame#session_detail [data-current-session-id='#{@session.id}']"
    assert_no_selector "turbo-frame#session_detail details[data-controller~='transcript-panel'][open]"

    within "turbo-frame#session_detail" do
      select "Show Logs", from: "log-level-filter"
    end

    assert_selector "turbo-frame#session_detail select#log-level-filter option[value='show-logs'][selected]",
                    visible: :all
    assert_no_selector "turbo-frame#session_detail details[data-controller~='transcript-panel'][open]"
    assert_selector "turbo-frame#session_detail[src*='filter=show-logs']", visible: :all
    refute_includes page.find("turbo-frame#session_detail", visible: :all)[:src].to_s, "transcript=open"
  end

  # The other half of the fix: with no enclosing frame the controller still
  # navigates the document, so the full session page behaves exactly as before.
  test "the full session page still restores the saved log level from localStorage" do
    visit session_path(@session)
    # connect() writes the rendered level to localStorage, so wait for the
    # controller to have run before overwriting it — otherwise the two writes
    # race and the controller's `minimal` can land last.
    wait_for_stimulus_controller("log-level-filter")
    page.execute_script("localStorage.setItem('logLevelFilter', 'show-logs')")

    # A fresh load with the preference saved and no filter param: connect()
    # navigates the document to add it.
    visit session_path(@session)

    assert_selector "select#log-level-filter option[value='show-logs'][selected]", visible: :all
    assert_match(/[?&]filter=show-logs/, page.current_url)
    assert_equal session_path(@session), URI.parse(page.current_url).path

    open_transcript_panel(wait: 5)
    assert_text LOG_LINE
  end

  test "changing the log level on the full session page navigates the document" do
    visit session_path(@session)
    assert_no_text LOG_LINE

    select "Show Logs", from: "log-level-filter"

    assert_selector "select#log-level-filter option[value='show-logs'][selected]", visible: :all
    assert_match(/[?&]filter=show-logs/, page.current_url)

    open_transcript_panel(wait: 5)
    assert_text LOG_LINE
  end

  # Same disclosure rule on the page that navigates the document: the address it
  # navigates to carries the open transcript, so the reader lands back on it.
  test "the full session page keeps an open transcript across a log level change" do
    visit session_path(@session)
    wait_for_stimulus_controller("log-level-filter")
    open_transcript_panel(wait: 5)
    assert_selector "details[data-controller~='transcript-panel'][open]"

    select "Show Logs", from: "log-level-filter"

    assert_selector "select#log-level-filter option[value='show-logs'][selected]", visible: :all
    assert_match(/[?&]filter=show-logs/, page.current_url)
    assert_match(/[?&]transcript=open/, page.current_url)
    assert_selector "details[data-controller~='transcript-panel'][open]"
    assert_text LOG_LINE
  end
end
