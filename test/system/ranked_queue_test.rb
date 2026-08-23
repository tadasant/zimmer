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
    page.execute_script("window.scrollTo(0, 0)")
    page.save_screenshot(SCREENSHOT_DIR.join("proof-#{name}.png"))
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

    kebab_for(queued).click
    assert_link "Start now"
    assert_link "Trash"
    capture("ranked-row-menu")

    # Start hands the session its first turn. The job is enqueued rather than run
    # (the test adapter holds it), so the session's own log is what says so.
    click_link "Start now"
    assert_selector "#flash", text: "starting now"
    assert queued.logs.reload.any? { |log| log.content.include?("Started now") },
      "Start now should record itself on the session it started"

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

    assert_selector "[data-ranked-queue-target='priorityList'] #ranked_row_#{queued.id}", wait: 5
    assert queued.logs.reload.any? { |log| log.content.include?("Started now") },
      "a promote should start the session rather than leave it waiting out its re-check"
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
