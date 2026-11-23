# frozen_string_literal: true

require "application_system_test_case"

# Your board follows sessions while it is open, with no reload.
#
# The bug this pins, as reported: with the Status filter on "Needs input" only,
# a card whose session was followed up on stayed on the board reading "Needs
# Input". Every open dashboard hears the same card delivery (`_card_delivery`);
# `board-v2` judges it against this page's filters and its categories.
#
# Every test ends by asserting that the page it looked at is the page it opened.
class BoardV2LiveTest < ApplicationSystemTestCase
  SCREENSHOT_DIR = Rails.root.join("tmp", "capybara")
  # A board narrowed to one genesis, so nothing but this file's sessions is on it.
  # Unlike a text search, a genesis filter still lets a session arrive live.
  GENESIS = SessionGenesis::WHATSAPP

  setup do
    page.driver.browser.manage.window.resize_to(1400, 1600)
    BoardCategory.delete_all
    @infra = BoardCategory.create!(name: "Infra")
    @research = BoardCategory.create!(name: "Research")
  end

  def make(title, category: nil, touched: nil, status: :needs_input, **attrs)
    attrs[:metadata] = { "last_user_activity_at" => touched.iso8601 } if touched
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "x",
      title: title, status: status, genesis: GENESIS, **attrs)
    session.update_columns(board_category_id: category.id) if category
    session
  end

  def visit_board(*statuses, **params)
    statuses = [ "needs_input" ] if statuses.empty?
    visit root_path({
      view: SessionsController::VIEW_MODE_BOARD_V2,
      SessionsController::FILTERS_SUBMITTED_PARAM => "1",
      "status" => statuses, genesis: GENESIS
    }.merge(params))
    assert_selector "#board_v2"
    wait_for_turbo_streams_connected
    page.execute_script(<<~JS)
      window.__boardProof = "no-navigation"
      window.__boardVisits = 0
      for (const name of ["turbo:visit", "turbo:before-render"]) {
        document.addEventListener(name, () => { window.__boardVisits += 1 })
      }
    JS
  end

  def assert_never_navigated
    assert_equal [ "no-navigation", 0 ], page.evaluate_script("[window.__boardProof, window.__boardVisits]"),
      "the board must follow over the stream, not through a reload"
  end

  def list(category)
    "#board_v2_list_#{category&.id || "uncategorized"}"
  end

  def row(session)
    "#board_v2_row_#{session.id}"
  end

  def assert_order(category, *sessions)
    expected = sessions.map { |session| "board_v2_row_#{session.id}" }
    actual = nil
    50.times do
      actual = page.evaluate_script("Array.from(document.querySelectorAll('#{list(category)} > li')).map((li) => li.id)")
      break if actual == expected

      sleep 0.1
    end
    assert_equal expected, actual
  end

  def assert_total(count)
    assert_selector "[data-board-v2-target='total']", exact_text: count.to_s, wait: 5
  end

  def assert_count(category, count)
    scope = category ? "[data-board-v2-target='category'][data-category-id='#{category.id}']" : "#board_v2"
    assert_equal count.to_s, first("#{scope} [data-board-v2-count]").text
  end

  def settle(seconds = 1)
    sleep seconds
  end

  def capture(name)
    page.execute_script("document.getElementById('board_v2').scrollIntoView({ block: 'start' })")
    FileUtils.mkdir_p(SCREENSHOT_DIR)
    page.save_screenshot(SCREENSHOT_DIR.join("proof-board-live-#{name}.png"))
  end

  # The report, exactly.
  test "a session that is followed up on leaves a needs-input board, handle and all, and the counts drop" do
    staying = make("Still needs you")
    leaving = make("Followed up on")
    visit_board
    assert_selector row(leaving)
    assert_total 2
    capture("1-before-leaving")

    leaving.update!(status: :running)

    assert_no_selector row(leaving), wait: 5
    assert_selector row(staying)
    assert_total 1
    assert_count nil, 1
    capture("2-after-leaving")

    leaving.update!(status: :waiting)
    settle
    assert_no_selector row(leaving)
    assert_never_navigated
  end

  test "a card that still matches is redrawn in place, and keeps its handle" do
    session = make("Goes from running to needing you", status: :running, category: @infra)
    visit_board "needs_input", "running"
    assert_selector row(session), text: "Running"

    session.update!(status: :needs_input)

    assert_selector "#{row(session)} turbo-frame", text: "Needs Input", wait: 5
    assert_selector "#{list(@infra)} > #{row(session)} [data-board-v2-target='handle']"
    assert_never_navigated
  end

  test "a session that starts matching arrives in its own category, in last-touched order" do
    newest = make("Touched just now", category: @infra, touched: 1.minute.ago)
    arrival = make("Comes to rest", category: @infra, touched: 1.hour.ago, status: :running)
    oldest = make("Touched yesterday", category: @infra, touched: 1.day.ago)
    visit_board
    assert_order @infra, newest, oldest
    capture("3-before-arriving")

    arrival.update!(status: :needs_input)

    assert_selector row(arrival), wait: 5
    assert_order @infra, newest, arrival, oldest
    assert_count @infra, 3
    assert_total 3
    assert_selector "#{row(arrival)} [data-board-v2-target='handle']"
    capture("4-after-arriving")
    assert_never_navigated
  end

  test "a new session arrives in Uncategorized only if the filters admit it, as a whole row" do
    visit_board
    stranger = make("Created running", status: :running)
    other_genesis = make("From somewhere else", genesis: SessionGenesis::SLACK)
    welcome = make("Created needing input")

    assert_selector "#{list(nil)} > #{row(welcome)}", wait: 5
    assert_no_selector row(stranger)
    assert_no_selector row(other_genesis)
    assert_total 1
    # A whole row: its card, its handle, and the Trash that takes both.
    assert_selector "#{row(welcome)} turbo-frame#session_#{welcome.id}", count: 1
    assert_selector "#{row(welcome)} [data-board-v2-target='handle']", count: 1
    within(row(welcome)) { click_on "Trash" }
    assert_no_selector row(welcome)
    assert_total 0
    assert_never_navigated
  end

  test "a session that is touched goes to the top of its category" do
    first = make("First", category: @infra, touched: 1.hour.ago)
    second = make("Second", category: @infra, touched: 2.hours.ago)
    visit_board
    assert_order @infra, first, second

    second.touch_user_activity!
    assert_order @infra, second, first

    travel 1.minute do
      first.reload.touch_user_view!
    end
    assert_order @infra, first, second
    assert_never_navigated
  end

  test "filing a session from elsewhere moves its card between categories and out again" do
    session = make("File me", touched: 1.hour.ago)
    neighbour = make("Already in Research", category: @research, touched: 1.minute.ago)
    visit_board
    assert_selector "#{list(nil)} > #{row(session)}"

    BoardCategories::Assign.call(session: session, category_id: @research.id)
    assert_order @research, neighbour, session
    assert_count @research, 2
    assert_order nil

    BoardCategories::Assign.call(session: session, category_id: nil)
    assert_order nil, session
    assert_order @research, neighbour
    assert_total 2
    assert_never_navigated
  end

  # A process that loaded the session before it was filed knows nothing of the
  # category: a delivery has to be rendered from the row, not from that copy.
  test "a delivery from a process holding an older copy does not undo the filing" do
    session = make("Filed while an agent ran")
    stale = Session.find(session.id)
    visit_board
    BoardCategories::Assign.call(session: session, category_id: @infra.id)
    assert_order @infra, session

    stale.update!(title: "Renamed by the older copy")

    assert_selector "#{list(@infra)} > #{row(session)}", text: "Renamed by the older copy", wait: 5
    assert_never_navigated
  end

  test "a session in a snoozed category never appears, and the category's count follows it" do
    parked = BoardCategory.create!(name: "Parked", visibility: "snoozed", snoozed_until: 2.days.from_now)
    tucked = "[data-board-v2-tucked-category='#{parked.id}']"
    session = make("Park me")
    quiet = make("Running in the parked category", category: parked, status: :running)
    visit_board
    assert_selector tucked, text: "0 sessions"

    BoardCategories::Assign.call(session: session, category_id: parked.id)
    assert_no_selector row(session), wait: 5
    assert_selector tucked, text: "1 session"
    assert_total 0

    quiet.update!(status: :needs_input)
    assert_selector tucked, text: "2 sessions", wait: 5
    assert_no_selector row(quiet)

    quiet.update!(status: :running)
    assert_selector tucked, text: "1 session", wait: 5

    BoardCategories::Assign.call(session: session, category_id: @infra.id)
    assert_selector "#{list(@infra)} > #{row(session)}", wait: 5
    assert_selector tucked, text: "0 sessions"
    assert_total 1
    assert_never_navigated
  end

  test "a hide, a backlog and a scheduling class set elsewhere are followed" do
    hidden = make("Hide me")
    backlogged = make("Backlog me")
    demoted = make("Demote me", scheduling_class: SessionGenesis::PRIORITY)
    visit_board priority_class: SessionGenesis::PRIORITY
    [ hidden, backlogged ].each { |s| s.update!(scheduling_class: SessionGenesis::PRIORITY) }
    assert_selector row(hidden), wait: 5
    assert_selector row(backlogged), wait: 5

    hidden.update!(visibility: "hidden")
    assert_no_selector row(hidden), wait: 5
    backlogged.update!(visibility: SessionVisibility::BACKLOGGED)
    assert_no_selector row(backlogged), wait: 5
    demoted.update!(scheduling_class: SessionGenesis::SPOT)
    assert_no_selector row(demoted), wait: 5
    assert_total 0

    hidden.update!(visibility: "visible")
    assert_selector row(hidden), wait: 5
    assert_never_navigated
  end

  test "a CarPlay fit set elsewhere is followed" do
    marked = make("Marked laptop only")
    visit_board carplay_fit: "not_laptop_only"
    assert_selector row(marked)

    marked.update!(carplay_fit: "laptop_only", carplay_fit_source: "human", carplay_fit_line_count: 0)
    assert_no_selector row(marked), wait: 5

    marked.update!(carplay_fit: "carplay_ok")
    assert_selector row(marked), wait: 5
    assert_never_navigated
  end

  # The server draws a capped board; a shorter cap stands in for 500 cards.
  test "an arrival on a full board pushes out the least recently touched" do
    newest = make("Newest", touched: 1.minute.ago)
    oldest = make("Oldest", touched: 2.hours.ago, category: @infra)
    visit_board
    page.execute_script("document.getElementById('board_v2').dataset.boardV2LimitValue = '2'")

    too_old = make("Older than everything shown", touched: 1.day.ago)
    arrival = make("Arrives", touched: 1.hour.ago)

    assert_selector row(arrival), wait: 5
    assert_no_selector row(oldest)
    assert_no_selector row(too_old)
    assert_selector row(newest)
    assert_total 2
    assert_selector "#board_v2_truncated", text: "most recently touched"
    assert_never_navigated
  end

  test "a title being typed on a card is not replaced, and the card catches up after" do
    session = make("Before")
    visit_board
    within(row(session)) { find("[data-action='click->editable-title#edit']").click }
    field = find("#{row(session)} input[data-editable-title-target='input']")
    field.set("Half a tit")

    session.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/test/repo/pull/7" ] })
    settle 1.5
    assert_equal "Half a tit", field.value

    field.send_keys(:escape)
    assert_selector "#{row(session)} a[href='https://github.com/test/repo/pull/7']", wait: 5
    assert_never_navigated
  end

  test "the no-match line shows when the last card leaves and goes when one arrives" do
    only = make("The only one")
    visit_board
    assert_no_selector "[data-board-v2-no-match]"

    only.update!(status: :running)
    assert_selector "[data-board-v2-no-match]", text: "No sessions match these filters.", wait: 5
    assert_selector "#board_v2", text: "Nothing uncategorized."

    only.update!(status: :needs_input)
    assert_selector row(only), wait: 5
    assert_no_selector "[data-board-v2-no-match]"
    assert_never_navigated
  end

  test "a searched board declines an arrival but still lets a card leave, and takes it back" do
    leaving = make("Zsearchedboard leaving")
    visit_board q: "Zsearchedboard"
    assert_selector row(leaving)

    stranger = make("Zsearchedboard arrived")
    leaving.update!(status: :running)

    assert_no_selector row(leaving), wait: 5
    assert_no_selector row(stranger)
    assert_never_navigated
  end

  test "a card trashed from this page stays gone on a board showing every status, and Undo brings back one" do
    doomed = make("Trash me", category: @infra)
    visit_board "needs_input", "running", "waiting", "failed", "archived"
    within(row(doomed)) { click_on "Trash" }

    assert_selector "#flash", text: "Session moved to trash."
    assert_no_selector row(doomed)
    settle
    assert_no_selector row(doomed)
    assert_count @infra, 0

    within("#flash") { click_on "Undo" }
    assert_selector "#{list(@infra)} > #{row(doomed)}", text: "Needs Input", wait: 5
    settle
    assert_selector "[id='board_v2_row_#{doomed.id}']", count: 1
    assert_selector "[id='session_#{doomed.id}']", count: 1
    assert_count @infra, 1
    assert_never_navigated
  end

  test "Undo puts a card back on a searched board too" do
    doomed = make("Zundosearch trash me", category: @infra)
    visit_board q: "Zundosearch"
    within(row(doomed)) { click_on "Trash" }
    assert_selector "#flash", text: "Session moved to trash."
    within("#flash") { click_on "Undo" }

    assert_selector "#{list(@infra)} > #{row(doomed)}", wait: 5
    assert_never_navigated
  end

  test "a card snoozed from this page is not resurrected by a delivery that follows" do
    session = make("Snooze me", category: @infra)
    visit_board
    find("#{row(session)} button[aria-label='More actions for session #{session.id}']").click
    within(row(session)) do
      click_on "Snooze until…"
      click_on "Move to backlog"
    end
    assert_no_selector row(session)
    settle 0.5
    assert session.reload.backlogged?

    session.update!(title: "Renamed while backlogged")
    settle
    assert_no_selector row(session)
    assert_count @infra, 0
    assert_never_navigated
  end

  test "nothing moves while a card is in hand, and what arrived is applied on the drop" do
    held = make("In my hand", touched: 1.minute.ago)
    leaving = make("Leaves meanwhile", touched: 1.hour.ago)
    visit_board
    driver = press_and_lift(row(held))

    leaving.update!(status: :running)
    held.update!(status: :running)
    settle
    assert_selector row(leaving)
    assert_selector row(held)

    driver.action.release.perform
    assert_no_selector row(leaving), wait: 5
    assert_no_selector row(held), wait: 5
    assert_total 0
    assert_never_navigated
  end

  test "a category made while a card is in hand appears after the drop" do
    session = make("In my hand")
    visit_board
    driver = press_and_lift(row(session))

    fresh = BoardCategory.create!(name: "Made mid-drag")
    settle
    assert_no_selector list(fresh), visible: :all

    driver.action.release.perform
    assert_selector list(fresh), wait: 8, visible: :all
    assert_never_navigated
  end

  # A delivery that only says a session was looked at is quick to render, so it can
  # overtake the one carrying the session's new card.
  test "a card that arrives after newer facts is still drawn, and an older one is not" do
    session = make("Out of order", status: :running, category: @infra)
    visit_board
    now = Time.current
    deliver(session, status: "needs_input", read_at: now, card: nil)
    assert_no_selector row(session)

    deliver(session, status: "running", read_at: now - 1.second, card: "The newest card")
    assert_selector "#{list(@infra)} > #{row(session)}", text: "The newest card"

    deliver(session, status: "running", read_at: now - 2.seconds, card: "An older card")
    settle 0.5
    assert_selector row(session), text: "The newest card"
    assert_never_navigated
  end

  test "a category made, renamed, reordered, snoozed, woken or deleted elsewhere is followed" do
    session = make("Ends up somewhere new")
    in_infra = make("Infra's own", category: @infra)
    visit_board

    fresh = BoardCategory.create!(name: "Made elsewhere")
    BoardCategories::Assign.call(session: session, category_id: fresh.id)
    assert_selector "#{list(fresh)} > #{row(session)}", wait: 8
    assert_selector "[data-board-v2-drop-zone][data-category-id='#{fresh.id}']", visible: :all
    assert_count fresh, 1

    fresh.update!(name: "Renamed elsewhere")
    assert_selector "[data-board-v2-group-name]", text: "Renamed elsewhere", wait: 8

    BoardCategories::Reorder.call(ids: [ fresh.id, @infra.id, @research.id ])
    assert_selector "[data-board-v2-target='categories'] > :first-child[data-category-id='#{fresh.id}']", wait: 8

    BoardCategories::SetVisibility.call(category: @infra, visibility: "backlogged")
    assert_no_selector row(in_infra), wait: 8
    assert_selector "[data-board-v2-tucked-category='#{@infra.id}']", text: "1 session"
    assert_total 1

    BoardCategories::SetVisibility.call(category: @infra, visibility: "visible")
    assert_selector "#{list(@infra)} > #{row(in_infra)}", wait: 8
    assert_no_selector "[data-board-v2-tucked-category='#{@infra.id}']"
    assert_total 2

    fresh.destroy!
    assert_selector "#{list(nil)} > #{row(session)}", wait: 8
    assert_no_selector list(fresh)
    assert_selector "[id='board_v2_row_#{session.id}']", count: 1
    assert_total 2
    assert_never_navigated
  end

  # Broadcasts sent while the socket is down are gone. Both ways back — a page
  # reopened after being away, and a socket that dropped under a visible page —
  # have to bring the board up to date from the server.
  test "a page reopened after its socket died catches up" do
    leaving, arriving, moved = missed_update_sessions
    visit_board
    kill_cable_socket(reconnect: false)
    apply_missed_updates(leaving, arriving, moved)
    settle 0.5
    assert_selector row(leaving)

    page.execute_script("window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true }))")
    assert_caught_up(leaving, arriving, moved)

    arriving.update!(status: :running)
    assert_no_selector row(arriving), wait: 8
    assert_never_navigated
  end

  test "a socket that drops and comes back under a visible page catches up" do
    leaving, arriving, moved = missed_update_sessions
    visit_board
    kill_cable_socket(reconnect: false)
    apply_missed_updates(leaving, arriving, moved)
    settle 0.5
    assert_selector row(leaving)

    page.execute_script(<<~JS)
      document.querySelector("turbo-cable-stream-source").subscription.consumer.connection.open()
    JS
    assert_caught_up(leaving, arriving, moved)
    assert_never_navigated
  end

  test "a catch-up that fails is tried again, without a visit" do
    leaving, arriving, moved = missed_update_sessions
    visit_board
    page.execute_script(<<~JS)
      document.querySelector("[data-controller~='stream-visibility-recovery']")
        .setAttribute("data-stream-visibility-recovery-resubscribe-retry-value", "200")
      const real = window.fetch
      window.__failedOnce = false
      window.fetch = (url, options) => {
        if (!window.__failedOnce && String(url) === window.location.href) {
          window.__failedOnce = true
          return Promise.reject(new TypeError("offline"))
        }
        return real(url, options)
      }
    JS
    kill_cable_socket(reconnect: false)
    apply_missed_updates(leaving, arriving, moved)
    page.execute_script('document.querySelector("turbo-cable-stream-source").subscription.consumer.connection.open()')

    assert_caught_up(leaving, arriving, moved)
    assert page.evaluate_script("window.__failedOnce")
    assert_never_navigated
  end

  test "at 375px a card leaves and one arrives live, and the board still fits the screen" do
    page.driver.browser.manage.window.resize_to(375, 812)
    leaving = make("Leaves on the phone")
    arriving = make("Arrives on the phone", category: @infra, status: :running)
    visit_board
    assert_selector row(leaving)
    capture("5-phone-before")

    leaving.update!(status: :running)
    arriving.update!(status: :needs_input)

    assert_no_selector row(leaving), wait: 5
    assert_selector "#{list(@infra)} > #{row(arriving)}", wait: 5
    assert page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1")
    capture("6-phone-after")
    assert_never_navigated
  end

  private

  # Press a card's grip and lift it far enough for the drag to start.
  def press_and_lift(css)
    page.execute_script("document.querySelector(#{css.to_json}).scrollIntoView({ block: 'center' })")
    x, y = page.evaluate_script(<<~JS)
      (() => {
        const r = document.querySelector(#{"#{css} [data-board-v2-target='handle']".to_json}).getBoundingClientRect()
        return [Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2)]
      })()
    JS
    driver = page.driver.browser
    driver.action.move_to_location(x, y).click_and_hold
      .move_to_location(x + 6, y + 6).move_to_location(x + 12, y + 12).move_to_location(x + 18, y + 18).perform
    assert_selector "[data-board-v2-target='tray']", visible: true
    driver
  end

  # A delivery put on the page by hand, for an order the server cannot be made to
  # send them in.
  def deliver(session, status:, read_at:, card:)
    html = ApplicationController.render(inline: <<~ERB, locals: { session: session, status: status, read_at: read_at, card: card })
      <div data-board-v2-target="delivery" hidden data-session-id="<%= session.id %>" data-status="<%= status %>"
           data-scheduling-class="priority" data-on-board="true" data-backlogged="false" data-carplay-fit="untagged"
           data-genesis="<%= session.genesis %>" data-agent-root="" data-board-category-id="<%= session.board_category_id %>"
           data-last-touched="<%= session.last_user_activity_at.to_f %>" data-read-at="<%= read_at.to_f * 1000 %>">
        <% if card %><template><turbo-frame id="session_<%= session.id %>" data-session-id="<%= session.id %>"><%= card %></turbo-frame></template><% end %>
      </div>
    ERB
    page.execute_script("document.getElementById('sessions_grid_deliveries').insertAdjacentHTML('beforeend', #{html.to_json})")
  end

  def missed_update_sessions
    [ make("Leaves while away"), make("Arrives while away", status: :running, category: @infra),
      make("Filed while away") ]
  end

  def apply_missed_updates(leaving, arriving, moved)
    leaving.update!(status: :running)
    arriving.update!(status: :needs_input)
    BoardCategories::Assign.call(session: moved, category_id: @research.id)
  end

  def assert_caught_up(leaving, arriving, moved)
    assert_no_selector row(leaving), wait: 8
    assert_selector "#{list(@infra)} > #{row(arriving)}", wait: 8
    assert_selector "#{list(@research)} > #{row(moved)}", wait: 8
    assert_total 2
    assert_count @research, 1
    assert_count nil, 0
  end

  def kill_cable_socket(reconnect:)
    page.execute_script(<<~JS)
      document.querySelector("turbo-cable-stream-source").subscription.consumer.connection.close({ allowReconnect: #{reconnect} })
    JS
    assert_no_selector "turbo-cable-stream-source[connected]", visible: :all, wait: 5
  end
end
