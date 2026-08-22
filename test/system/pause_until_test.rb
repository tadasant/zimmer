require "application_system_test_case"

# "Pause Until" — the browser half of the wake mechanism. The parts that can only
# break in a browser are the ones worth driving here: the card's overflow menu
# opening at all, a preset resolving to a real future instant in the BROWSER's
# timezone, the datetime-picker fallback, and the menu staying on-screen at a
# phone width.
class PauseUntilTest < ApplicationSystemTestCase
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

  def open_card_menu(session)
    find("##{ActionView::RecordIdentifier.dom_id(session)} button[aria-label='More actions for session #{session.id}']").click
  end

  # The picker is a native datetime-local control, so its value is set the way the
  # browser would set it and an input event is dispatched for anything listening.
  def set_picker(value)
    input = find("input[type='datetime-local']", visible: true)
    page.execute_script(<<~JS, input, value)
      arguments[0].value = arguments[1];
      arguments[0].dispatchEvent(new Event("input", { bubbles: true }));
    JS
  end

  test "a preset in the card's overflow menu sleeps the session and schedules the wake" do
    session = create_session
    visit root_path
    assert_text "Waiting on the deploy"

    open_card_menu(session)
    click_on "Pause Until…"
    assert_text "In 1 hour"

    assert_difference "Trigger.count", 1 do
      click_on "In 1 hour"
      # The sleep broadcasts a replacement card, which tears the panel (and its
      # confirmation line) out of the DOM. The badge is what a user is left
      # looking at, so that is what this waits on.
      assert_selector "##{ActionView::RecordIdentifier.dom_id(session)}", text: "Waiting"
    end

    assert session.reload.waiting?

    trigger = Trigger.order(:id).last
    assert trigger.reuse_session
    assert_equal session.id, trigger.last_session_id

    condition = trigger.trigger_conditions.sole
    assert condition.one_time_schedule?
    # The wake lands roughly an hour out — the point being that it is a real future
    # instant, not a naive local string the server misread as UTC.
    fires_at = ActiveSupport::TimeZone[condition.schedule_timezone].parse(condition.scheduled_at)
    assert_in_delta 1.hour.from_now.to_i, fires_at.to_i, 5.minutes.to_i
  end

  test "the datetime picker schedules an arbitrary time" do
    session = create_session
    visit root_path
    assert_text "Waiting on the deploy"

    open_card_menu(session)
    click_on "Pause Until…"

    target = 3.days.from_now.change(hour: 14, min: 45, sec: 0)
    set_picker(target.strftime("%Y-%m-%dT%H:%M"))

    assert_difference "Trigger.count", 1 do
      click_on "Schedule"
      assert_selector "##{ActionView::RecordIdentifier.dom_id(session)}", text: "Waiting"
    end

    assert session.reload.waiting?
    assert_equal target.strftime("%Y-%m-%dT%H:%M:00"), Trigger.order(:id).last.trigger_conditions.sole.scheduled_at
  end

  test "a custom resume prompt is used in place of the default" do
    session = create_session
    visit root_path
    assert_text "Waiting on the deploy"

    open_card_menu(session)
    click_on "Pause Until…"
    find("textarea[id^='pause_until_prompt_']").set("Re-check the deploy")
    click_on "In 15 minutes"
    assert_selector "##{ActionView::RecordIdentifier.dom_id(session)}", text: "Waiting"

    assert_equal "Re-check the deploy", Trigger.order(:id).last.prompt_template
  end

  test "the detail page schedules a wake from its own control" do
    session = create_session
    visit session_path(session)

    click_on "Pause Until"
    assert_text "In 15 minutes"

    assert_difference "Trigger.count", 1 do
      click_on "In 3 hours"
      assert_selector "#session_#{session.id}_status_badge", text: "Waiting"
    end

    assert session.reload.waiting?
  end

  test "a past time is refused with a message rather than bricking the session" do
    session = create_session
    visit session_path(session)

    click_on "Pause Until"
    # The picker's own `min` blocks this in a real interaction; setting the value
    # directly is how a stale panel or a hand-edited DOM would reach the server.
    set_picker(2.days.ago.strftime("%Y-%m-%dT%H:%M"))

    assert_no_difference "Trigger.count" do
      # js_click, not click_on: the detail page's sticky header sits over the
      # popover at some scroll positions, and Selenium clicks by coordinate.
      js_click(find("button[data-action='pause-until#chooseCustom']"))
      assert_text(/already passed/)
    end

    assert session.reload.needs_input?
  end

  test "a session the auto-sleep would no-op gets no control at all" do
    failed = create_session(title: "Died on a bad clone", status: :failed)
    visit root_path
    # The dashboard defaults to the needs_input slice, so a failed session is not
    # on it until its status is filtered in.
    check "status-filter-failed", allow_label_click: true
    click_on "Apply filters"
    assert_text "Died on a bad clone"

    assert_no_selector "##{ActionView::RecordIdentifier.dom_id(failed)} button[aria-label='More actions for session #{failed.id}']"

    visit session_path(failed)
    assert_no_button "Pause Until"
  end

  test "the detail page panel opens fully on screen at a phone width" do
    session = create_session
    page.driver.browser.manage.window.resize_to(375, 812)

    visit session_path(session)
    # A phone gets the joystick's bottom sheet, not the `hidden md:block` header.
    # The sheet is revealed directly rather than by driving the press-and-hold
    # gesture: what is under test here is the panel this partial renders, and the
    # gesture has its own coverage.
    assert_selector "[data-joystick-menu-target='sheet']", visible: :all
    page.execute_script(<<~JS)
      const sheet = document.querySelector("[data-joystick-menu-target='sheet']");
      sheet.classList.remove("translate-y-full", "opacity-0");
    JS
    click_on "Pause Until…"
    assert_text "In 1 hour"

    left, past_right, doc_overflow = page.evaluate_script(<<~JS)
      (function () {
        const p = document.querySelector("[data-pause-until-target='panel']:not(.hidden)");
        const b = p.getBoundingClientRect();
        return [Math.round(b.left), Math.round(b.right - document.documentElement.clientWidth),
                document.documentElement.scrollWidth - document.documentElement.clientWidth];
      })()
    JS

    assert left >= 0, "the Pause Until panel starts #{-left}px off the left edge at 375px"
    assert past_right <= 1, "the Pause Until panel runs #{past_right}px past the right edge at 375px"
    assert doc_overflow <= 0, "opening the panel makes the page scroll sideways by #{doc_overflow}px"
  ensure
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  test "a session queued for spawn is offered no control, on either surface" do
    # `waiting` is also the AASM initial state. Such a session is not asleep — it
    # is waiting to be started — and pausing it would arm a wake `start` never
    # consumes.
    queued = create_session(title: "Queued behind the clone", status: :waiting)
    assert_nil queued.session_id

    visit session_path(queued)
    assert_text "Queued behind the clone"
    assert_no_button "Pause Until"

    visit root_path
    check "status-filter-waiting", allow_label_click: true
    click_on "Apply filters"
    assert_text "Queued behind the clone"
    assert_no_selector "##{ActionView::RecordIdentifier.dom_id(queued)} button[aria-label='More actions for session #{queued.id}']"
  end

  # The choice in the same panel that is not a time. What makes it worth driving
  # in a browser is the pair of outcomes: the session sleeps, and NOTHING is
  # armed to wake it — which is the difference a unit test can assert but only a
  # real click through the panel can demonstrate.
  test "Spot Queue parks the session with no trigger, from the card menu" do
    session = create_session
    visit root_path
    assert_text "Waiting on the deploy"

    open_card_menu(session)
    click_on "Pause Until…"
    assert_text "Spot Queue"

    assert_no_difference "Trigger.count" do
      click_on "Spot Queue"
      assert_selector "##{ActionView::RecordIdentifier.dom_id(session)}", text: "Waiting"
    end

    session.reload
    assert session.waiting?
    assert SpotSessionPause.queued_by_user?(session), "the sweep finds it by this record"
    assert_not session.awaiting_scheduled_wake?
    assert session.spot?, "a priority session cannot sit in the spot queue"
  end

  test "the detail page offers Spot Queue and confirms the park" do
    session = create_session
    visit session_path(session)

    click_on "Pause Until"
    assert_text "Spot Queue"
    # Evidence for the PR: the panel as the operator sees it on the detail page,
    # with the new option beside the time presets.
    page.save_screenshot("tmp/screenshots/proof-spot-queue-detail-desktop.png")

    assert_no_difference "Trigger.count" do
      js_click(find("button[data-action='pause-until#chooseSpotQueue']"))
      # The park broadcasts a replacement header, which tears the panel (and its
      # confirmation line) out of the DOM — so the badge is what to wait on.
      assert_selector "#session_#{session.id}_status_badge", text: "Waiting"
    end

    assert session.reload.waiting?
  end

  test "the mobile sheet offers Spot Queue on screen at a phone width" do
    session = create_session
    page.driver.browser.manage.window.resize_to(375, 812)

    visit session_path(session)
    assert_selector "[data-joystick-menu-target='sheet']", visible: :all
    page.execute_script(<<~JS)
      const sheet = document.querySelector("[data-joystick-menu-target='sheet']");
      sheet.classList.remove("translate-y-full", "opacity-0");
    JS
    click_on "Pause Until…"
    assert_text "Spot Queue"
    page.save_screenshot("tmp/screenshots/proof-spot-queue-sheet-375.png")

    # The option has to be reachable, not merely present: a row whose right edge
    # sits past the viewport is a control nobody on a phone can press.
    left, past_right, doc_overflow = page.evaluate_script(<<~JS)
      (function () {
        const b = document.querySelector("[data-action='pause-until#chooseSpotQueue']").getBoundingClientRect();
        return [Math.round(b.left), Math.round(b.right - document.documentElement.clientWidth),
                document.documentElement.scrollWidth - document.documentElement.clientWidth];
      })()
    JS

    assert left >= 0, "the Spot Queue row starts #{-left}px off the left edge at 375px"
    assert past_right <= 1, "the Spot Queue row runs #{past_right}px past the right edge at 375px"
    assert doc_overflow <= 0, "the panel makes the page scroll sideways by #{doc_overflow}px"

    assert_no_difference "Trigger.count" do
      click_on "Spot Queue"
      # visible: :all — the detail page's badge lives in the `hidden md:block`
      # header, which is exactly what a phone does not get.
      assert_selector "#session_#{session.id}_status_badge", text: "Waiting", visible: :all
    end
    assert session.reload.waiting?
  ensure
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  test "the card menu opens fully on screen at a phone width" do
    session = create_session
    page.driver.browser.manage.window.resize_to(375, 812)

    visit root_path
    assert_text "Waiting on the deploy"

    open_card_menu(session)
    click_on "Pause Until…"
    assert_text "In 1 hour"

    # The panel is only usable if it is actually within the viewport — a menu that
    # renders past the right edge on a phone is a control nobody can press.
    overflow = page.evaluate_script(<<~JS)
      (function () {
        const panel = document.querySelector("[data-pause-until-target='panel']:not(.hidden)");
        const b = panel.getBoundingClientRect();
        return [Math.round(b.left), Math.round(b.right - document.documentElement.clientWidth),
                document.documentElement.scrollWidth - document.documentElement.clientWidth];
      })()
    JS
    left, past_right, doc_overflow = overflow

    assert left >= 0, "the Pause Until panel starts #{-left}px off the left edge at 375px"
    assert past_right <= 1, "the Pause Until panel runs #{past_right}px past the right edge at 375px"
    assert doc_overflow <= 0, "opening the Pause Until panel makes the page scroll sideways by #{doc_overflow}px"
  ensure
    page.driver.browser.manage.window.resize_to(1400, 900)
  end
end
