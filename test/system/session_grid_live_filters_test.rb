require "application_system_test_case"

# The dashboard's card grid (the Last Touched and Created views) has to stay true
# to the filters it was rendered with while sessions change under it.
#
# The bug this pins, as reported: with the Status filter on "Needs input" only, a
# card whose session moved to `waiting` stayed on the page with its new status.
# Every open dashboard hears the same broadcast and the server cannot know their
# filters, so the card arrives as an envelope (`_card_delivery`) and the page's
# `session-grid` controller decides what to do with it.
class SessionGridLiveFiltersTest < ApplicationSystemTestCase
  SCREENSHOT_DIR = Rails.root.join("tmp", "capybara")

  def make(title:, status: :needs_input, created_at: Time.current, **attrs)
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "x",
      title: title, status: status, created_at: created_at, **attrs)
  end

  def visit_grid(params = {})
    visit root_path({ view: SessionsController::VIEW_MODE_LAST_TOUCHED }.merge(params))
    assert_selector "[data-controller='session-grid']"
    wait_for_turbo_streams_connected
    page.execute_script("window.__gridProof = 'no-navigation';")
  end

  def visit_grid_showing(*statuses, **params)
    visit_grid({ SessionsController::FILTERS_SUBMITTED_PARAM => "1", "status" => statuses }.merge(params))
  end

  def page_never_navigated?
    page.evaluate_script("window.__gridProof === 'no-navigation'")
  end

  def card_selector(session)
    "#sessions_grid > turbo-frame#session_#{session.id}"
  end

  def shown_count
    find("[data-session-grid-target='count']").text.to_i
  end

  def grid_ids
    all("#sessions_grid > turbo-frame").map { |frame| frame[:id] }
  end

  # The grid sits below the Filters panel, so a shot of the top of the document
  # would show none of it.
  def capture(name)
    page.execute_script("document.getElementById('flat_sessions').scrollIntoView({ block: 'start' })")
    FileUtils.mkdir_p(SCREENSHOT_DIR)
    page.save_screenshot(SCREENSHOT_DIR.join("proof-grid-#{name}.png"))
  end

  test "a card whose session leaves the status filter leaves the page, and the count follows" do
    leaving = make(title: "Goes back to waiting")
    staying = make(title: "Still needs you")

    visit_grid_showing("needs_input")
    assert_selector card_selector(leaving)
    assert_selector card_selector(staying)
    before = shown_count
    capture("1-before")

    leaving.update!(status: :waiting)

    assert_no_selector card_selector(leaving), wait: 5
    assert_selector card_selector(staying)
    assert_equal before - 1, shown_count
    capture("2-after-status-change")
    assert page_never_navigated?, "the card must leave over the stream, not via a reload"
  end

  test "a session that starts matching arrives in sort order" do
    top = make(title: "Touched just now")
    arrival = make(title: "Comes to rest needing you", status: :running, created_at: 1.hour.ago)
    bottom = make(title: "Touched yesterday", created_at: 1.day.ago)

    visit_grid_showing("needs_input")
    assert_selector card_selector(top)
    assert_no_selector card_selector(arrival)
    before = shown_count

    arrival.update!(status: :needs_input)

    assert_selector card_selector(arrival), wait: 5
    ids = grid_ids
    assert_operator ids.index("session_#{top.id}"), :<, ids.index("session_#{arrival.id}")
    assert_operator ids.index("session_#{arrival.id}"), :<, ids.index("session_#{bottom.id}")
    assert_equal before + 1, shown_count
    capture("3-arrival")
    assert page_never_navigated?
  end

  test "a session created elsewhere arrives only if the filter admits it" do
    visit_grid_showing("needs_input")

    stranger = make(title: "Created running", status: :running)
    welcome = make(title: "Created needing input")

    assert_selector card_selector(welcome), wait: 5
    assert_equal "session_#{welcome.id}", grid_ids.first
    assert_no_selector card_selector(stranger)
    assert page_never_navigated?
  end

  test "a trashed card leaves a page of live work but stays, relabelled, on one showing the trash" do
    doomed = make(title: "Trash me but let me be seen")

    visit_grid_showing("needs_input", "archived")
    assert_selector card_selector(doomed)

    doomed.update!(status: :archived)

    assert_selector card_selector(doomed), text: "Trashed", wait: 5
    assert page_never_navigated?
  end

  # The flip side of the test above. A board showing every status admits a
  # trashed session, but the operator who clicked Trash on this page asked for the
  # card to go, and the archive broadcast that follows must not put it back.
  test "a card trashed from this page stays gone on a board showing every status" do
    doomed = make(title: "Trash me from here")

    visit_grid(every_status_params)
    assert_selector card_selector(doomed)

    within(card_selector(doomed)) { click_on "Trash" }

    assert_selector "#flash", text: "Session moved to trash."
    assert doomed.reload.archived?
    # The archive broadcast went out with the commit; give it the same window
    # every arrival in this file gets.
    assert_no_selector card_selector(doomed), wait: 2
    sleep 1
    assert_no_selector card_selector(doomed), wait: 0
    assert page_never_navigated?
  end

  # Undo puts the card back through the same envelope, inside the grace window
  # that otherwise refuses deliveries for a card this page just took away.
  test "Undo puts a card trashed from a filtered board back on it" do
    doomed = make(title: "Trash me, then think better of it")

    visit_grid_showing("needs_input")
    assert_selector card_selector(doomed)
    before = shown_count

    within(card_selector(doomed)) { click_on "Trash" }
    assert_selector "#flash", text: "Session moved to trash."
    assert_no_selector card_selector(doomed)

    within("#flash") { click_on "Undo" }

    assert_selector card_selector(doomed), text: "Needs Input", wait: 5
    assert_equal before, shown_count
    assert page_never_navigated?
  end

  test "a card snoozed elsewhere leaves a board showing only on-board sessions" do
    snoozed = make(title: "Snooze me from another tab")

    visit_grid_showing("needs_input")
    assert_selector card_selector(snoozed)

    snoozed.update!(visibility: "hidden")

    assert_no_selector card_selector(snoozed), wait: 5
    assert page_never_navigated?
  end

  test "a card whose scheduling class leaves the filter leaves the page" do
    demoted = make(title: "Demote me", scheduling_class: SessionGenesis::PRIORITY)

    visit_grid_showing("needs_input", priority_class: SessionGenesis::PRIORITY)
    assert_selector card_selector(demoted)

    demoted.update!(scheduling_class: SessionGenesis::SPOT)

    assert_no_selector card_selector(demoted), wait: 5
    assert page_never_navigated?
  end

  # The genesis filter narrows the board to sessions this test made, so the grid
  # can actually run dry — and fill again.
  test "the empty state appears when the last card leaves and goes when one arrives" do
    only = make(title: "The only WhatsApp session", genesis: SessionGenesis::WHATSAPP)

    visit_grid_showing("needs_input", genesis: SessionGenesis::WHATSAPP)
    assert_selector card_selector(only)
    assert_selector "[data-session-grid-target='empty']", visible: :hidden

    only.update!(status: :running)
    assert_no_selector card_selector(only), wait: 5
    assert_selector "[data-session-grid-target='empty']", visible: true
    assert_selector "#flat_sessions", visible: :hidden

    other_genesis = make(title: "From Slack", genesis: SessionGenesis::SLACK)
    arrival = make(title: "Another WhatsApp session", genesis: SessionGenesis::WHATSAPP)

    assert_selector card_selector(arrival), wait: 5
    assert_no_selector card_selector(other_genesis)
    assert_selector "[data-session-grid-target='empty']", visible: :hidden
    assert_equal 1, shown_count
    assert page_never_navigated?
  end

  # A page narrowed by a text search cannot judge whether an unseen session
  # matches it, so it declines to insert. Removal stays live.
  test "a searched grid declines an arrival but still lets a card leave" do
    tag = "Zgridsearchfixture"
    leaving = make(title: "#{tag} leaving")

    visit_grid_showing("needs_input", q: tag)
    assert_selector card_selector(leaving)

    stranger = make(title: "#{tag} arrived")
    leaving.update!(status: :waiting)

    assert_no_selector card_selector(leaving), wait: 5
    assert_no_selector card_selector(stranger)
    assert page_never_navigated?
  end
end
