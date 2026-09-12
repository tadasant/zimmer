require "application_system_test_case"

# The dashboard's User view as a board somebody works top to bottom: the drag
# that reorders it, and the three row actions that take a session off it.
#
# The drag is the part that cannot be an integration test. SortableJS is driven
# through its own pointer events, and the reorder it persists is a real
# scheduling write, so this is the only place it is proven end to end.
class UserViewBoardTest < ApplicationSystemTestCase
  # Every row this test makes carries this token and the board is opened with it
  # as the search query — the suite loads `fixtures :all`, so an unfiltered board
  # is full of sessions this test did not create and cannot count.
  TAG = "Zboardfixture".freeze

  def spot(precedence, title:, status: :needs_input, custom_metadata: {})
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "x",
      title: "#{TAG} #{title}", status: status,
      scheduling_class: SessionGenesis::SPOT, precedence: precedence,
      custom_metadata: custom_metadata)
  end

  def priority(title:, precedence: 0)
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "x",
      title: "#{TAG} #{title}", status: :needs_input,
      scheduling_class: SessionGenesis::PRIORITY, precedence: precedence)
  end

  def visit_board(status: nil)
    params = { view: SessionsController::VIEW_MODE_USER, q: TAG }
    params = params.merge(SessionsController::FILTERS_SUBMITTED_PARAM => "1", status: status) if status
    visit root_path(params)
  end

  def row_ids
    all("#user_view_list li[id^='user_view_row_']").map { |el| el[:id] }
  end

  # A drag persists over a PATCH and the list re-sorts when the answer lands, so
  # the order is only settled asynchronously. `all` does not wait, so a bare
  # assert_equal on row_ids races the round trip; this polls it instead.
  def assert_row_order(expected, message, wait: Capybara.default_max_wait_time)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    actual = row_ids
    while actual != expected && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      sleep 0.15
      actual = row_ids
    end
    assert_equal expected, actual, message
  end

  # A press-and-move through the driver rather than dispatched MouseEvents:
  # SortableJS binds `pointerdown`, and a synthetic MouseEvent never reaches it,
  # so a scripted "drag" would silently prove nothing.
  #
  # Selenium's Actions API does NOT scroll to its target the way `click` does — it
  # dispatches at viewport coordinates and raises MoveTargetOutOfBounds for
  # anything off-screen — so the row is centred first.
  # Stimulus controllers load asynchronously, so a row can be on the page a beat
  # before the Sortable that makes it draggable is — and a drop pressed in that beat
  # silently does nothing, which is a green test that proves nothing.
  def wait_for_drag_and_drop(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      armed = page.evaluate_script(
        "(() => { const l = document.getElementById('user_view_list'); return !!(l && l.sortableInstance) })()"
      )
      return if armed
      raise "the User view's drag-and-drop never armed within #{timeout}s" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
  end

  # Press and hold a row's handle and move the pointer — a REAL press through the
  # driver, not a dispatched MouseEvent, because SortableJS binds `pointerdown` and a
  # synthetic MouseEvent never reaches it.
  #
  # What this proves is that the handle is a live drag handle: the drag starts and
  # SortableJS takes the row (`.sortable-ghost`). It deliberately does NOT assert the
  # drop, because where SortableJS *seats* a row is decided by its own pointer
  # arithmetic and a WebDriver's synthesised moves do not reproduce it reliably. The
  # seating and everything downstream of it is asserted by #drop_row_between below,
  # which drives the controller's own drop handler.
  def start_drag_and_hold(session)
    wait_for_drag_and_drop
    page.execute_script(
      "document.getElementById(#{"user_view_row_#{session.id}".to_json}).scrollIntoView({ block: 'center' })"
    )
    handle = find("#user_view_row_#{session.id} [data-user-view-target='handle']")
    page.driver.browser.action.move_to(handle.native).click_and_hold.move_by(0, 12).move_by(0, -40).perform
  end

  def release_drag
    page.driver.browser.action.release.perform
  end

  # A drop, driven at the seam SortableJS hands the controller: the row is moved in
  # the DOM and `persistDrop` is called with the indices SortableJS would report.
  #
  # This is the half of the interaction that is Zimmer's own code — which neighbours
  # the drop names, what the server derives from them, what the client does with the
  # answer, and where the list settles — and it is asserted end to end, against the
  # real endpoint and the real database. SortableJS's pointer arithmetic is the other
  # half, and it is theirs.
  def drop_row_between(session, above:, below:)
    wait_for_drag_and_drop
    page.execute_script(<<~JS)
      (() => {
        const list = document.getElementById("user_view_list");
        const row = document.getElementById(#{"user_view_row_#{session.id}".to_json});
        const oldIndex = Array.from(list.children).indexOf(row);
        const anchor = #{above ? "document.getElementById(#{"user_view_row_#{above.id}".to_json})" : "null"};
        if (anchor) {
          anchor.after(row);
        } else {
          list.prepend(row);
        }
        const newIndex = Array.from(list.children).indexOf(row);
        const controller = window.Stimulus.getControllerForElementAndIdentifier(
          document.getElementById("user_view"), "user-view");
        controller.persistDrop({ oldIndex, newIndex, item: row });
      })()
    JS
  end

  test "a row's handle really starts a drag" do
    top = spot(900, title: "Top of the board")
    spot(100, title: "Bottom of the board")

    visit_board
    start_drag_and_hold(top)

    assert_selector "#user_view_list .sortable-ghost", visible: :all
    release_drag
  end

  test "dropping a row between two others rewrites its precedence and survives a reload" do
    top = spot(900, title: "Top of the board")
    middle = spot(500, title: "Middle of the board")
    bottom = spot(100, title: "Bottom of the board")

    visit_board
    assert_row_order([ "user_view_row_#{top.id}", "user_view_row_#{middle.id}", "user_view_row_#{bottom.id}" ],
      "the board should open in precedence order")

    drop_row_between(bottom, above: top, below: middle)

    assert_row_order([ "user_view_row_#{top.id}", "user_view_row_#{bottom.id}", "user_view_row_#{middle.id}" ],
      "the dropped row should be sitting between the two it was dropped between")

    # The write, not just the DOM: precedence is a real scheduling signal, and the
    # server is what derives the value from the two neighbours it was handed.
    assert_operator bottom.reload.precedence, :>, middle.reload.precedence
    assert_operator bottom.precedence, :<, top.reload.precedence

    visit_board
    assert_row_order([ "user_view_row_#{top.id}", "user_view_row_#{bottom.id}", "user_view_row_#{middle.id}" ],
      "the dropped order has to survive a reload — it is stored, not a display preference")
  end

  # Precedence cannot express "this spot session outranks that priority one", so a
  # row dropped outside its own class block is reseated into it rather than the board
  # pretending the drop landed. The neighbours the client sends are the nearest rows
  # of the SAME class, which for a drop at the very top is none at all.
  test "a spot row dropped into the priority block settles back below it" do
    above = priority(title: "Priority above", precedence: 10)
    spot_row = spot(100, title: "Spot below")

    visit_board
    assert_row_order([ "user_view_row_#{above.id}", "user_view_row_#{spot_row.id}" ],
      "the board should open with the priority row on top")

    drop_row_between(spot_row, above: nil, below: above)

    assert_row_order([ "user_view_row_#{above.id}", "user_view_row_#{spot_row.id}" ],
      "a spot row cannot be ranked above a priority one")
    assert_equal SessionGenesis::PRIORITY, above.reload.priority_class,
      "and nothing about the drop changed anybody's scheduling class"
  end

  test "Trash takes the row off the board without a reload, and offers Undo" do
    doomed = spot(100, title: "Trash me")
    kept = spot(200, title: "Keep me")

    visit_board
    page.execute_script("window.__boardProof = 'no-navigation';")

    find("#user_view_row_#{doomed.id} form[action='#{archive_session_path(doomed)}'] button").click

    assert_no_selector "#user_view_row_#{doomed.id}"
    assert_selector "#user_view_row_#{kept.id}"
    assert_text "Session moved to trash."
    assert_selector "#flash form[action='#{undo_archive_session_path(doomed)}']"
    assert page.evaluate_script("window.__boardProof === 'no-navigation'"),
      "the row has to leave over a turbo stream, not by reloading the board"
    assert_equal "archived", doomed.reload.status
  end

  test "Snooze takes the row off the board and leaves the session's rank alone" do
    snoozing = spot(100, title: "Snooze me")

    visit_board
    find("#user_view_row_#{snoozing.id} [data-visibility-target='button']").click
    assert_selector "#user_view_row_#{snoozing.id} button[data-preset='tomorrow']"
    find("#user_view_row_#{snoozing.id} button[data-preset='tomorrow']").click

    assert_no_selector "#user_view_row_#{snoozing.id}", wait: 5
    assert_equal SessionVisibility::SNOOZED, snoozing.reload.visibility
    assert_equal 100, snoozing.precedence, "snoozing is presentation only — it must not touch the queue"
    assert_equal "needs_input", snoozing.status
  end

  # The Merge button is the one sanctioned path for an agent to merge its own
  # work, so what this pins is that the click both reaches the session AND is
  # legible afterwards.
  test "Merge sends the authorization and the button says it has been sent" do
    url = "https://github.com/o/r/pull/9"
    green = spot(100, title: "Green PR", status: :running, custom_metadata: {
      "github_pull_request_urls" => [ url ],
      "github_pull_request_statuses" => { url => "open" },
      "github_pull_request_ci_statuses" => { url => "pass" }
    })

    # `running` is outside the board's default status filter (`needs_input` alone),
    # so the filter is submitted explicitly — otherwise the row this test is about
    # is not on the page at all.
    visit_board(status: [ "running" ])
    assert_selector "#user_view_merge_#{green.id} button", text: "Merge"

    find("#user_view_merge_#{green.id} button").click

    assert_selector "#user_view_merge_#{green.id}", text: "Merge sent"
    assert_no_selector "#user_view_merge_#{green.id} button"

    queued = green.enqueued_messages.pending.last
    assert AutomatedPrompts.merge_authorization?(queued.content)
    assert_includes queued.content, url
  end

  test "a PR that is not green offers no Merge button at all" do
    url = "https://github.com/o/r/pull/10"
    red = spot(100, title: "Red PR", custom_metadata: {
      "github_pull_request_urls" => [ url ],
      "github_pull_request_statuses" => { url => "open" },
      "github_pull_request_ci_statuses" => { url => "fail" }
    })

    visit_board

    assert_selector "#user_view_row_#{red.id}"
    assert_no_selector "#user_view_merge_#{red.id} button"
  end
end
