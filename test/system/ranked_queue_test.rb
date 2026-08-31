require "application_system_test_case"

# The Ranked view as a queue dashboard: it has to stay current on its own, and
# its per-row actions have to be reachable with a thumb and with a keyboard.
#
# The staleness this pins is the one the operator reported — statuses on
# `/?view=ranked` did not move until the page was reloaded, because the card
# grid's broadcast targets `dom_id(session)` and a ranked row is not a card.
class RankedQueueTest < ApplicationSystemTestCase
  # Every row this test makes carries this token, and the view is opened with it
  # as the search query — the suite loads `fixtures :all`, so an unfiltered queue
  # is full of sessions this test did not create and cannot count.
  TAG = "Zqueuefixture".freeze

  def spot(precedence, title:, status: :waiting)
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "x",
      title: "#{TAG} #{title}", status: status,
      scheduling_class: SessionGenesis::SPOT, precedence: precedence)
  end

  def priority(title:, precedence: 0)
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "x",
      title: "#{TAG} #{title}", status: :waiting,
      scheduling_class: SessionGenesis::PRIORITY, precedence: precedence)
  end

  def visit_queue
    visit root_path(view: SessionsController::VIEW_MODE_RANKED, q: TAG)
  end

  # The queue WITHOUT a search query, which is the only way a live insert is on:
  # the client cannot evaluate a search for a session it has never rendered, so a
  # searched page declines to insert. Tests that assert an arrival use this and
  # name their own rows rather than counting the whole list.
  def visit_open_queue(params = {})
    visit root_path({ view: SessionsController::VIEW_MODE_RANKED }.merge(params))
  end

  # The same, with an explicit Filters submission — this is how an operator ticks
  # "Archived" to go through the trash.
  def visit_queue_showing(*statuses)
    visit_open_queue(SessionsController::FILTERS_SUBMITTED_PARAM => "1", "status" => statuses)
  end

  def ranked_queue_controller_script(expression)
    "window.Stimulus.getControllerForElementAndIdentifier(" \
      "document.getElementById('ranked_sessions'), 'ranked-queue').#{expression}"
  end

  # How many deliveries the controller is holding until the drag ends. Polled,
  # because it is a broadcast arriving over a websocket.
  def held_delivery_count(wait: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    loop do
      count = page.evaluate_script(ranked_queue_controller_script("heldDeliveries.length"))
      return count if count.positive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.1
    end
  end

  # A token that survives Turbo Stream updates and dies on any navigation, so
  # "without a reload" is an assertion rather than a hope.
  def stamp_page
    page.execute_script("window.__rankedProof = 'no-navigation';")
  end

  def page_never_navigated?
    page.evaluate_script("window.__rankedProof === 'no-navigation'")
  end

  def kebab_for(session)
    find("#ranked_row_#{session.id} button[aria-label='More actions for session #{session.id}']")
  end

  # The computed `display` of a row's drag handle. A class-list assertion would
  # pass on markup the browser renders visible.
  def handle_display(session)
    page.evaluate_script(
      "getComputedStyle(document.querySelector(#{"#ranked_row_#{session.id} [data-ranked-queue-target='handle']".to_json})).display"
    )
  end

  # The computed `display` of one of a row's two menu entries. The menu itself is
  # hidden, so this reads the entry's own display rather than its visibility.
  def menu_item_display(session, target)
    page.evaluate_script(
      "getComputedStyle(document.querySelector(#{"#ranked_row_#{session.id} [data-ranked-queue-target='#{target}']".to_json})).display"
    )
  end

  def spot_row_ids
    all("[data-ranked-queue-target='spotList'] > li").map { |li| li[:id] }
  end

  # Screenshots land next to the failure screenshots Rails writes, so CI's
  # artifact upload picks them up and a PR can show what changed. There is no
  # Postgres in an agent session's container, so CI's Chrome is the only place a
  # screenshot of this screen can come from.
  SCREENSHOT_DIR = Rails.root.join("tmp", "capybara")

  def capture(name)
    FileUtils.mkdir_p(SCREENSHOT_DIR)
    page.save_screenshot(SCREENSHOT_DIR.join("proof-#{name}.png"))
  end

  # The queue sits below the filters panel, so a shot framed on the top of the
  # document shows the filters and none of the rows. Scroll BEFORE opening a menu
  # rather than after: overflow-menu decides up-or-down from where the button is
  # in the viewport at the moment it opens.
  def scroll_queue_into_view
    page.execute_script("document.getElementById('ranked_sessions').scrollIntoView({ block: 'start' })")
  end

  test "the queue follows status changes live, and a trashed row leaves it" do
    queued = spot(900, title: "Rebuild the AIR catalog index")
    doomed = spot(100, title: "Second in line")
    priority(title: "Ship the hotfix")

    visit_queue
    wait_for_turbo_streams_connected

    assert_selector "#ranked_row_status_#{queued.id}", text: "Waiting"
    assert_selector "[data-ranked-queue-target='spotCount']", exact_text: "2"
    assert_selector "[data-ranked-queue-target='priorityCount']", exact_text: "1"

    # The whole walk the operator watches, without touching the page.
    queued.update!(status: :running)
    assert_selector "#ranked_row_status_#{queued.id}", text: "Running", wait: 5

    queued.update!(status: :needs_input)
    assert_selector "#ranked_row_status_#{queued.id}", text: "Needs input", wait: 5

    # The rest of the row is untouched by a status broadcast: the rank the user
    # can be mid-edit on is exactly what a whole-row replace would have thrown away.
    assert_equal "900", find("#precedence_input_#{queued.id}").value
    assert_equal [ "ranked_row_#{queued.id}", "ranked_row_#{doomed.id}" ], spot_row_ids

    # Trashing a session takes its row out of the queue, and the header count and
    # the empty-state placeholder follow it — those are recounted by the
    # MutationObserver, not re-rendered by the server.
    doomed.update!(status: :archived)
    assert_no_selector "#ranked_row_#{doomed.id}", wait: 5
    assert_selector "[data-ranked-queue-target='spotCount']", exact_text: "1"
    assert_selector "#ranked_row_#{queued.id}"
  end

  test "row actions live behind a three-dot menu that promotes, demotes and closes" do
    top = priority(title: "Ship the hotfix")
    queued = spot(100, title: "Rebuild the AIR catalog index")

    visit_queue
    assert_selector "#ranked_row_#{top.id}"

    # Nothing inline: the demote action is in the DOM but not on the row.
    assert_no_button "Demote to spot"
    assert_no_button "Promote to priority"

    kebab = kebab_for(top)
    assert_equal "false", kebab["aria-expanded"]
    # Keyboard-reachable: focus it and press Enter rather than clicking it.
    kebab.send_keys(:enter)
    assert_equal "true", kebab["aria-expanded"]
    assert_button "Demote to spot"
    assert_no_button "Promote to priority", visible: true

    # Escape closes it, and so does a click anywhere else.
    kebab.send_keys(:escape)
    assert_no_button "Demote to spot"
    assert_equal "false", kebab["aria-expanded"]

    kebab.click
    assert_button "Demote to spot"
    find("h2", text: "Ranked").click
    assert_no_button "Demote to spot"

    # And the action itself still works, and closes the menu behind it.
    kebab.click
    click_button "Demote to spot"
    assert_selector "[data-ranked-queue-target='spotList'] #ranked_row_#{top.id}", wait: 5
    assert_no_button "Demote to spot"
    assert_selector "[data-ranked-queue-target='priorityCount']", exact_text: "0"
    assert_selector "[data-ranked-queue-target='spotCount']", exact_text: "2"
    assert_selector "[data-ranked-queue-target='priorityEmpty']", text: "No priority sessions"

    # A demoted row swaps its menu entry along with its rank cell.
    kebab_for(top).click
    assert_button "Promote to priority"
    assert_no_button "Demote to spot"
    click_button "Promote to priority"
    assert_selector "[data-ranked-queue-target='priorityList'] #ranked_row_#{top.id}", wait: 5
    assert_selector "[data-ranked-queue-target='spotCount']", exact_text: "1"
    assert_selector "[data-ranked-queue-target='priorityCount']", exact_text: "1"
    assert_equal [ "ranked_row_#{queued.id}" ], spot_row_ids
  end

  # A priority row has no rank to order by, so it must not offer a drag handle —
  # and "must not" here is a rendered-CSS claim, not a class-list one. Tailwind
  # emits `.inline-flex` after `.hidden`, so a display utility on the handle would
  # silently beat the `hidden` that hides it and every priority row would sprout a
  # handle that drags nothing. Assert the computed display, which is the only thing
  # that settles it.
  test "only spot rows offer a drag handle" do
    top = priority(title: "Ship the hotfix")
    queued = spot(100, title: "Rebuild the AIR catalog index")

    visit_queue
    assert_selector "#ranked_row_#{top.id}"

    assert_equal "none", handle_display(top), "a priority row must not show a drag handle"
    # Same shape, same guard: a display utility next to the conditional `hidden`
    # on either menu entry would show both, and a class-list assertion would not
    # notice.
    assert_equal "none", menu_item_display(top, "promoteAction"), "a priority row must not offer Promote"
    assert_equal "none", menu_item_display(queued, "demoteAction"), "a spot row must not offer Demote"
    assert_not_equal "none", handle_display(queued), "a spot row must show its drag handle"

    # And the handle follows the row when it changes sections, without a reload.
    kebab_for(top).click
    click_button "Demote to spot"
    assert_selector "[data-ranked-queue-target='spotList'] #ranked_row_#{top.id}", wait: 5
    assert_not_equal "none", handle_display(top), "a demoted row must gain its handle"
  end

  # Everything a row can do now lives in the one menu, so the two entries added
  # last are exercised where a user meets them: in the open menu, on a row.
  test "the menu trashes a row and starts a session" do
    doomed = spot(200, title: "Trash me from the menu")
    queued = spot(100, title: "Rebuild the AIR catalog index")

    visit_queue
    wait_for_turbo_streams_connected
    assert_selector "[data-ranked-queue-target='spotCount']", exact_text: "2"

    scroll_queue_into_view
    kebab_for(queued).click
    assert_link "Start now"
    assert_link "Trash"
    capture("ranked-row-menu")

    # Start hands the session its first turn. The job is enqueued rather than run
    # (the test adapter holds it), so the session's own log is what says so.
    click_link "Start now"
    assert_selector "#flash", text: "next turn is due now"
    assert_eventually "Start now should record itself on the session it started" do
      queued.logs.reload.any? { |log| log.content.include?("Started now") }
    end

    # Trash archives through the same #archive every other Trash affordance posts
    # to, and the row leaves over the ranked stream rather than by a reload.
    kebab_for(doomed).click
    click_link "Trash"
    assert_no_selector "#ranked_row_#{doomed.id}", wait: 5
    assert doomed.reload.archived?
    assert_selector "[data-ranked-queue-target='spotCount']", exact_text: "1"
  end

  # Promoting a held session is the whole point of promoting it: the deferred
  # re-check it was carrying is up to an hour out, and the hold banner already
  # promised that making it priority starts it now.
  test "promoting a row starts the session it promoted" do
    queued = spot(100, title: "Held behind the quota gate")

    visit_queue
    kebab_for(queued).click
    click_button "Promote to priority"

    # The row reaching the priority list does not mean the promote has finished.
    # `broadcast_ranked_membership` fires from the `after_commit` of the
    # scheduling-class write, so the delivery that moves the row can land while
    # the request thread is still in `start_after_promotion` — the read of the
    # log it writes has to wait for it rather than take the DOM's word for it.
    assert_selector "[data-ranked-queue-target='priorityList'] #ranked_row_#{queued.id}", wait: 5
    assert_eventually "a promote should start the session rather than leave it waiting out its re-check" do
      queued.logs.reload.any? { |log| log.content.include?("Started now") }
    end
  end

  # The title is the reading surface of a queue row, and clicking it should not
  # take the operator off the queue they are managing. It stays a real <a href>,
  # so middle-click and ⌘/Ctrl-click still open a new tab — session-drawer#open
  # intercepts the plain left click only.
  test "clicking a row's title opens the drawer instead of leaving the queue" do
    queued = spot(100, title: "Rebuild the AIR catalog index")

    visit_queue
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='true']", visible: :all

    find("#ranked_row_#{queued.id} a", text: "Rebuild the AIR catalog index").click

    assert_selector "[data-session-drawer-target='panel'][aria-hidden='false']"
    assert_current_path root_path, ignore_query: true
    within "turbo-frame#session_detail" do
      assert_text "##{queued.id}"
    end
    capture("ranked-title-opens-drawer")
  end

  # The other half of the same promise, asserted on the guard itself: a click
  # carrying a modifier is left to the browser, which is what makes "open in a new
  # tab" keep working.
  #
  # The event is synthetic so the driver never has to chase a second tab, and a
  # one-shot preventDefault is attached AFTER Stimulus's own listener — dispatching
  # a click on an <a> follows the link whether the event is trusted or not, and a
  # navigation here would prove nothing about the drawer either way. Listener order
  # is what makes that honest: session-drawer#open runs first and gets the real
  # event, and only then is the browser's own navigation suppressed.
  test "a modifier-click on a row's title is left to the browser" do
    queued = spot(100, title: "Rebuild the AIR catalog index")

    visit_queue
    assert_selector "#ranked_row_#{queued.id} a", text: "Rebuild the AIR catalog index"

    page.execute_script(<<~JS, queued.id)
      const id = arguments[0];
      const link = [...document.querySelectorAll(`#ranked_row_${id} a`)]
        .find((a) => a.getAttribute("data-action") === "click->session-drawer#open");
      link.addEventListener("click", (event) => event.preventDefault(), { once: true });
      link.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, button: 0, metaKey: true }));
    JS

    # A plain click on this same link opens the drawer synchronously (the test
    # above), so the panel still being dismissed is the guard having returned.
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='true']", visible: :all
    assert_current_path root_path, ignore_query: true
  end

  # ---- Rows entering and leaving live -----------------------------------------

  # The first half of what the operator reported: a session created anywhere else
  # did not show up until the page was reloaded.
  test "a session created elsewhere arrives in the right section at the right rank" do
    middle = spot(500, title: "Already in the queue")
    bottom = spot(100, title: "Bottom of the queue")

    visit_open_queue
    wait_for_turbo_streams_connected
    stamp_page
    assert_selector "#ranked_row_#{middle.id}"

    # Created from outside the page entirely — no form, no click, no navigation.
    arrival = spot(300, title: "Arrived while you were watching")
    assert_selector "[data-ranked-queue-target='spotList'] #ranked_row_#{arrival.id}", wait: 5

    # And in ITS PLACE, not merely appended: 500 > 300 > 100.
    ids = spot_row_ids
    assert_operator ids.index("ranked_row_#{middle.id}"), :<, ids.index("ranked_row_#{arrival.id}")
    assert_operator ids.index("ranked_row_#{arrival.id}"), :<, ids.index("ranked_row_#{bottom.id}")

    # A spot row arrives able to be dragged and edited, like one the server rendered.
    assert_not_equal "none", handle_display(arrival)
    assert_equal "300", find("#precedence_input_#{arrival.id}").value

    assert page_never_navigated?, "the row must arrive over the stream, not via a reload"
  end

  test "a priority session created elsewhere arrives in the Priority section" do
    visit_open_queue
    wait_for_turbo_streams_connected
    stamp_page

    arrival = priority(title: "Ship the hotfix")
    assert_selector "[data-ranked-queue-target='priorityList'] #ranked_row_#{arrival.id}", wait: 5

    # A priority row has no rank to order by, so it arrives without a handle.
    assert_equal "none", handle_display(arrival)
    assert page_never_navigated?
  end

  # The second half of the report — and the half the old broadcast got wrong in
  # BOTH directions. It removed unconditionally, so a page filtered to live work
  # was right by accident and a page filtered to the trash was wrong.
  test "a trashed row leaves a queue showing live work" do
    doomed = spot(200, title: "Trash me")

    visit_open_queue
    wait_for_turbo_streams_connected
    stamp_page
    assert_selector "#ranked_row_#{doomed.id}"

    doomed.update!(status: :archived)
    assert_no_selector "#ranked_row_#{doomed.id}", wait: 5
    assert page_never_navigated?
  end

  test "a trashed row stays, relabelled, on a queue whose operator ticked Archived" do
    doomed = spot(200, title: "Trash me but let me be seen")

    visit_queue_showing("waiting", "running", "needs_input", "archived")
    wait_for_turbo_streams_connected
    stamp_page
    assert_selector "#ranked_row_status_#{doomed.id}", text: "Waiting"

    doomed.update!(status: :archived)

    # It must NOT vanish — this operator ticked "Archived" precisely to see it.
    assert_selector "#ranked_row_status_#{doomed.id}", text: "Trashed", wait: 5
    assert_selector "#ranked_row_#{doomed.id}"
    assert page_never_navigated?
  end

  # A promote or demote in another tab regroups the row here, without a reload.
  test "a scheduling class changed elsewhere moves the row between sections" do
    queued = spot(400, title: "Promote me from another tab")

    visit_open_queue
    wait_for_turbo_streams_connected
    stamp_page
    assert_selector "[data-ranked-queue-target='spotList'] #ranked_row_#{queued.id}"

    queued.update!(scheduling_class: SessionGenesis::PRIORITY)
    assert_selector "[data-ranked-queue-target='priorityList'] #ranked_row_#{queued.id}", wait: 5
    # The controls follow it: a priority row drags nothing.
    assert_equal "none", handle_display(queued)
    assert page_never_navigated?
  end

  # A page narrowed by a search cannot judge whether an unseen session matches it,
  # so it declines to insert rather than guessing. Removal is a different question
  # and stays live — a row on screen already matched the search.
  test "a searched queue declines an arrival but still lets a trashed row leave" do
    doomed = spot(200, title: "Trash me")

    visit_queue
    wait_for_turbo_streams_connected
    stamp_page
    assert_selector "#ranked_row_#{doomed.id}"

    # Matches the search, but the client has no way to know that.
    stranger = spot(300, title: "Arrived while you were watching")
    doomed.update!(status: :archived)

    assert_no_selector "#ranked_row_#{doomed.id}", wait: 5
    assert_no_selector "#ranked_row_#{stranger.id}"
    assert page_never_navigated?
  end

  # ---- The spinner --------------------------------------------------------------

  # The queue is read to answer "what is actually moving right now", and it has to
  # answer that live — the spinner rides the same pill replacement the status text
  # does.
  test "a running row spins, and stops when it stops running" do
    queued = spot(600, title: "Watch me start and stop")

    visit_open_queue
    wait_for_turbo_streams_connected
    assert_no_selector "#ranked_row_status_#{queued.id} svg"

    queued.update!(status: :running)
    assert_selector "#ranked_row_status_#{queued.id}", text: "Running", wait: 5
    assert_includes find("#ranked_row_status_#{queued.id} svg")[:class], "motion-safe:animate-spin",
      "the spinner must not animate for a reader who asked their OS for reduced motion"
    scroll_queue_into_view
    capture("ranked-running-spinner")

    queued.update!(status: :needs_input)
    assert_selector "#ranked_row_status_#{queued.id}", text: "Needs input", wait: 5
    assert_no_selector "#ranked_row_status_#{queued.id} svg"
  end

  # ---- The interactions the narrowness was protecting ---------------------------

  # The bar the prior work set and this one has to hold: a number typed but not
  # committed survives everything arriving over the stream — including an insert
  # and a removal, which the old broadcast never did.
  test "an uncommitted precedence survives arrivals, removals and regroupings" do
    typing = spot(700, title: "I am being edited")
    doomed = spot(200, title: "Trash me")

    visit_open_queue
    wait_for_turbo_streams_connected
    stamp_page

    input = find("#precedence_input_#{typing.id}")
    input.fill_in with: "12345"

    # Everything the stream can now do, while that field holds an uncommitted value.
    arrival = spot(400, title: "Arrived mid-edit")
    doomed.update!(status: :archived)
    typing.update!(status: :running)

    assert_selector "#ranked_row_#{arrival.id}", wait: 5
    assert_no_selector "#ranked_row_#{doomed.id}", wait: 5
    assert_selector "#ranked_row_status_#{typing.id}", text: "Running", wait: 5

    assert_equal "12345", find("#precedence_input_#{typing.id}").value,
      "a broadcast must never clobber a precedence the user is halfway through typing"
    assert page_never_navigated?
  end

  # A row the operator is editing is never taken away or moved, even when the
  # filters say it should go — the same rule the reconnect backfill applies. The
  # staleness is recovered by a reload; the half-typed number would not be.
  test "a row holding an uncommitted value is not evicted out from under it" do
    typing = spot(700, title: "I am being edited")

    visit_open_queue
    wait_for_turbo_streams_connected

    find("#precedence_input_#{typing.id}").fill_in with: "999"
    typing.update!(status: :archived)

    # The pill tells the truth; the row stays because someone is working in it.
    assert_selector "#ranked_row_status_#{typing.id}", text: "Trashed", wait: 5
    assert_selector "#ranked_row_#{typing.id}"
    assert_equal "999", find("#precedence_input_#{typing.id}").value
  end

  # …and the guard is exactly that narrow. "Someone is working in it" means a
  # focused TEXT FIELD, not any focused element — because the row's own ⋮ menu is
  # inside the row, so clicking its Trash entry leaves focus on a link in the very
  # row that click archived. A broader rule refuses to remove that row, which is
  # the staleness this whole change exists to fix, reintroduced by its own safety
  # net. ("the menu trashes a row" above is the end-to-end version; this is the
  # rule itself, with no menu in the way.)
  test "a row whose button holds focus is still evicted" do
    doomed = spot(200, title: "Focus is on my menu button")

    visit_open_queue
    wait_for_turbo_streams_connected
    stamp_page

    kebab_for(doomed).click
    assert_button "Promote to priority"

    doomed.update!(status: :archived)
    assert_no_selector "#ranked_row_#{doomed.id}", wait: 5
    assert page_never_navigated?
  end

  # The other interaction the narrow broadcast was protecting. SortableJS is driven
  # through its own pointer events rather than through Capybara's drag, so the drag
  # is genuinely in progress — `onStart` has fired — when the broadcast lands.
  test "a delivery arriving mid-drag waits for the drop" do
    top = spot(900, title: "Dragging me")
    spot(100, title: "Bottom of the queue")

    visit_open_queue
    wait_for_turbo_streams_connected
    stamp_page

    # A REAL press-and-move through the driver, not dispatched MouseEvents:
    # SortableJS binds `pointerdown`, and a synthetic MouseEvent never reaches it,
    # so a scripted "drag" would silently prove nothing.
    #
    # Scroll the row to the middle of the viewport first. The queue sits below the
    # filters panel, and Selenium's Actions API does NOT scroll to its target the
    # way `click` does — it dispatches at viewport coordinates and raises
    # MoveTargetOutOfBounds for anything off-screen.
    page.execute_script(
      "document.getElementById(#{"ranked_row_#{top.id}".to_json}).scrollIntoView({ block: 'center' })"
    )
    handle = find("#ranked_row_#{top.id} [data-ranked-queue-target='handle']")
    page.driver.browser.action
      .move_to(handle.native)
      .click_and_hold
      .move_by(0, 35)
      .move_by(0, 35)
      .perform

    assert_equal true, page.evaluate_script(ranked_queue_controller_script("dragging")),
      "the drag must actually be in progress for this test to mean anything"

    arrival = spot(400, title: "Arrived mid-drag")

    # Wait for the envelope to actually ARRIVE and be parked, so the absence
    # asserted below is the hold doing its job rather than the broadcast being
    # slower than the assertion.
    assert_equal 1, held_delivery_count(wait: 5)
    assert_no_selector "#ranked_row_#{arrival.id}"
    assert_equal 0, page.evaluate_script("document.getElementById('ranked_deliveries').children.length"),
      "the envelope is consumed on arrival and held in the controller, not left in the DOM"

    page.driver.browser.action.release.perform

    # Dropped — and the row the stream was holding lands, in its place.
    assert_selector "#ranked_row_#{arrival.id}", wait: 5
    assert page_never_navigated?
  end

  # The inline rank entry is the other half of this screen, and the row rewrite
  # moved the field. This is the regression guard for it.
  test "typing a rank and pressing Enter still reorders the queue" do
    low = spot(10, title: "Bottom of the queue")
    high = spot(900, title: "Top of the queue")

    visit_queue
    assert_equal [ "ranked_row_#{high.id}", "ranked_row_#{low.id}" ], spot_row_ids

    input = find("#precedence_input_#{low.id}")
    input.fill_in with: "1500"
    input.send_keys(:enter)

    assert_equal [ "ranked_row_#{low.id}", "ranked_row_#{high.id}" ], spot_row_ids
    assert_equal 1500, low.reload.precedence
  end
end
