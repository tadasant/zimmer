require "application_system_test_case"

# Queueing a message never stops the page. The message shows in the queue at the
# click as a placeholder, the composer is empty and usable at once, and the
# server's answer swaps the placeholder for the real row (lib/optimistic_queue.js).
#
# Only a browser can prove the "at the click" half, so these hold the server's
# answer back: `window.fetch` is wrapped so requests to one path wait until the
# test releases them, or fail as an unreachable server fails.
class OptimisticQueueTest < ApplicationSystemTestCase
  SCREENSHOT_DIR = Rails.root.join("tmp", "capybara")

  setup do
    @session = Session.create!(
      prompt: "Initial prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
  end

  test "the composer is usable the moment a message is queued, before the server answers" do
    visit session_path(@session)
    assert_button "Queue Message"
    hold_fetch_for("/sessions/#{@session.id}/enqueued_messages")

    fill_in "follow_up_prompt", with: "First queued message"
    click_button "Queue Message"

    # The server has not answered, yet the message is in the queue and the
    # composer is empty, enabled and focused.
    assert_selector "[data-pending-enqueued-message='queueing']", text: "First queued message", wait: 2
    textarea = find("textarea[name='follow_up_prompt']")
    assert_empty textarea.value
    assert_button "Queue Message", disabled: false
    assert_selector "[data-character-counter-target='counter']", text: "0 / ", visible: true
    assert_equal textarea[:id], page.evaluate_script("document.activeElement.id")

    # The next message can be typed and queued straight away.
    textarea.send_keys("Second queued message")
    click_button "Queue Message"
    assert_selector "[data-pending-enqueued-message='queueing']", count: 2
    capture("queue-at-the-click")

    # The server answers: both land, in the order they were written, and the
    # placeholders give way to the real rows.
    release_held_fetches
    assert_no_selector "[data-pending-enqueued-message]", wait: 5
    assert_selector ".bg-indigo-100", text: "2"
    assert_equal [ "First queued message", "Second queued message" ], @session.enqueued_messages.ordered.pluck(:content)
    @session.enqueued_messages.each { |message| assert_selector "#enqueued_message_#{message.id}" }
  end

  test "Send Now on a message still being queued sends it once the server has it" do
    visit session_path(@session)
    hold_fetch_for("/sessions/#{@session.id}/enqueued_messages")

    fill_in "follow_up_prompt", with: "Urgent queued message"
    click_button "Queue Message"

    within("[data-pending-enqueued-message='queueing']") { click_button "Send Now" }
    assert_selector "[data-pending-enqueued-message='queueing']", text: "sends as soon as it is queued"

    release_held_fetches

    assert_no_selector "[data-pending-enqueued-message]", wait: 10
    # Sent, not left waiting in the queue: the interrupt took it.
    assert_eventually { @session.logs.where("content LIKE ?", "%sent as interrupt via web: Urgent queued message%").exists? }
    assert_equal 0, @session.enqueued_messages.pending.count
    assert_no_selector "[id^='enqueued_message_']"
  end

  test "a queue the server never receives puts the words back in an empty composer" do
    visit session_path(@session)
    reject_fetch_for("/sessions/#{@session.id}/enqueued_messages")

    fill_in "follow_up_prompt", with: "Message that will not land"
    click_button "Queue Message"

    assert_selector "#flash [data-client-toast='alert']", text: "It is back in the composer", wait: 5
    assert_equal "Message that will not land", find("textarea[name='follow_up_prompt']").value
    assert_no_selector "[data-pending-enqueued-message]"
    assert_equal 0, @session.enqueued_messages.count
  end

  test "a queue the server refuses shows its reason and puts the words back" do
    visit session_path(@session)
    # The composer checks length and emptiness itself, so the server's refusal is
    # stood in for: a 422 stream carrying the reason, as #create answers one.
    page.execute_script(<<~JS, @session.id)
      const sessionId = arguments[0]
      const real = window.fetch
      window.fetch = (resource, options) => {
        const url = typeof resource === "string" ? resource : resource.url
        if (url.endsWith(`/sessions/${sessionId}/enqueued_messages`)) {
          const body = '<turbo-stream action="update" target="enqueued_messages_form_errors"><template><p>Refused for a reason</p></template></turbo-stream>'
          return Promise.resolve(new Response(body, { status: 422, headers: { "Content-Type": "text/vnd.turbo-stream.html; charset=utf-8" } }))
        }
        return real.call(window, resource, options)
      }
    JS

    fill_in "follow_up_prompt", with: "Message the server refuses"
    click_button "Queue Message"

    assert_selector "#enqueued_messages_form_errors", text: "Refused for a reason", wait: 5
    assert_selector "#flash [data-client-toast='alert']", text: "The server answered 422"
    assert_equal "Message the server refuses", find("textarea[name='follow_up_prompt']").value
    assert_no_selector "[data-pending-enqueued-message]"
  end

  test "a message is not queued while one of its attachments is still uploading" do
    visit session_path(@session)
    page.execute_script(<<~JS)
      const panel = document.querySelector("[data-controller~='file-attachment']")
      window.Stimulus.getControllerForElementAndIdentifier(panel, "file-attachment").uploadTotal = 1
    JS

    fill_in "follow_up_prompt", with: "Message with an upload in flight"
    click_button "Queue Message"

    assert_selector "#flash [data-client-toast='alert']", text: "Wait for the attachments to finish uploading", wait: 2
    assert_equal "Message with an upload in flight", find("textarea[name='follow_up_prompt']").value
    assert_no_selector "[data-pending-enqueued-message]"
  end

  test "a failed queue stays as a row with Retry when the user has started the next message" do
    visit session_path(@session)
    hold_fetch_for("/sessions/#{@session.id}/enqueued_messages")

    fill_in "follow_up_prompt", with: "Message to retry"
    click_button "Queue Message"
    find("textarea[name='follow_up_prompt']").send_keys("The next message")

    fail_held_fetches
    assert_selector "[data-pending-enqueued-message='failed']", text: "Message to retry", wait: 5
    assert_selector "[data-pending-enqueued-message='failed']", text: "Not queued"
    assert_equal "The next message", find("textarea[name='follow_up_prompt']").value
    capture("queue-failed-row")

    stop_holding_fetches
    within("[data-pending-enqueued-message='failed']") { click_button "Retry" }

    assert_no_selector "[data-pending-enqueued-message]", wait: 5
    assert_equal [ "Message to retry" ], @session.enqueued_messages.pluck(:content)
    assert_equal "The next message", find("textarea[name='follow_up_prompt']").value
  end

  test "the drawer's transcript and links stay live while a queue or a send is in flight" do
    visit root_url(every_status_params(view: SessionsController::VIEW_MODE_CREATED_DESC))
    find("a[aria-label='View session #{@session.id}']").click
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='false']"
    hold_fetch_for("/sessions/#{@session.id}/enqueued_messages")

    within "[data-session-drawer-target='panel']" do
      fill_in "follow_up_prompt", with: "Queued from the drawer"
      click_button "Queue Message"
      assert_selector "[data-pending-enqueued-message='queueing']", wait: 2
    end
    assert_drawer_live
    capture("drawer-live-while-queueing")

    # A held send (no turn underway) marks the frame busy through Turbo; the
    # drawer still is not dimmed or made inert.
    @session.update!(status: :needs_input)
    visit root_url(every_status_params(view: SessionsController::VIEW_MODE_CREATED_DESC))
    find("a[aria-label='View session #{@session.id}']").click
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='false']"
    within("[data-session-drawer-target='panel']") { assert_button "Send Message" }
    hold_fetch_for("/sessions/#{@session.id}/follow_up")

    within "[data-session-drawer-target='panel']" do
      fill_in "follow_up_prompt", with: "Sent from the drawer"
      click_button "Send Message"
    end
    assert_selector "turbo-frame#session_detail[busy]", wait: 2
    assert_drawer_live

    # A link in the drawer is followed while the send is still in flight.
    find("turbo-frame#session_detail a[aria-label='Expand to full page']", match: :first).click
    assert_current_path session_path(@session), ignore_query: true, wait: 5
  end

  test "on a phone the placeholder and a failed row fit the screen and the composer stays usable" do
    page.driver.browser.manage.window.resize_to(375, 812)
    visit session_path(@session)
    find("[data-bottom-drawer-target='trigger'] button").click
    hold_fetch_for("/sessions/#{@session.id}/enqueued_messages")

    mobile = find("#session_#{@session.id}_follow_up_textarea_mobile")
    mobile.fill_in(with: "A long queued message from a phone, long enough to need truncating in the row " * 3)
    find("[data-follow-up-prompt-target='submitButtonMobile']").click

    assert_selector "[data-pending-enqueued-message='queueing']", wait: 2
    assert_empty mobile.value
    mobile.send_keys("next")
    fail_held_fetches
    assert_selector "[data-pending-enqueued-message='failed']", wait: 5
    within("[data-pending-enqueued-message='failed']") do
      assert_button "Retry"
      assert_button "Discard"
    end

    assert page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1"),
      "the page is wider than a phone"
    # Scoped to the composer this test drives: the page's off-canvas panels (the
    # closed sidebar, the chat bubble) sit past the right edge by design.
    sticking_out = page.evaluate_script(<<~JS)
      (function () {
        const limit = document.documentElement.clientWidth;
        return Array.from(document.querySelectorAll("#session_#{@session.id}_follow_up_form *"))
          .filter((el) => el.getBoundingClientRect().right > limit + 1)
          .slice(0, 20)
          .map((el) => `${el.tagName.toLowerCase()}.${el.classList.value} @ ${Math.round(el.getBoundingClientRect().right)}px`);
      })()
    JS
    assert_empty sticking_out, "elements past the right edge at 375px"
    capture("queue-failed-row-375")
  ensure
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  private

  def assert_drawer_live
    style = page.evaluate_script(<<~JS)
      (() => {
        const frame = document.querySelector("turbo-frame#session_detail")
        const s = getComputedStyle(frame)
        return { pointerEvents: s.pointerEvents, opacity: s.opacity }
      })()
    JS
    assert_not_equal "none", style["pointerEvents"], "the drawer swallows clicks while the request is in flight"
    assert_equal "1", style["opacity"], "the drawer is dimmed while the request is in flight"
  end

  def assert_eventually(timeout: Capybara.default_max_wait_time)
    deadline = Time.current + timeout
    sleep 0.1 until yield || Time.current > deadline
    assert yield, "condition never became true"
  end

  # Requests to `path` wait until the test releases them (`release_held_fetches`)
  # or fails them (`fail_held_fetches`); anything else goes through.
  def hold_fetch_for(path)
    page.execute_script(<<~JS, path)
      const path = arguments[0]
      const real = window.__realFetch || window.fetch
      window.__realFetch = real
      window.__held = []
      window.__holding = true
      window.fetch = (resource, options) => {
        const url = typeof resource === "string" ? resource : resource.url
        if (window.__holding && url.includes(path)) {
          return new Promise((resolve, reject) => {
            window.__held.push({
              release: () => real.call(window, resource, options).then(resolve, reject),
              fail: () => reject(new TypeError("Failed to fetch"))
            })
          })
        }
        return real.call(window, resource, options)
      }
    JS
  end

  def release_held_fetches
    page.execute_script("window.__holding = false; window.__held.splice(0).forEach((h) => h.release())")
  end

  def fail_held_fetches
    page.execute_script("window.__held.splice(0).forEach((h) => h.fail())")
  end

  def stop_holding_fetches
    page.execute_script("window.__holding = false")
  end

  # A request to `path` fails as an unreachable server fails: the promise rejects.
  def reject_fetch_for(path)
    page.execute_script(<<~JS, path)
      const path = arguments[0]
      const real = window.fetch
      window.fetch = (resource, options) => {
        const url = typeof resource === "string" ? resource : resource.url
        if (url.includes(path)) return Promise.reject(new TypeError("Failed to fetch"))
        return real.call(window, resource, options)
      }
    JS
  end

  def capture(name)
    FileUtils.mkdir_p(SCREENSHOT_DIR)
    page.save_screenshot(SCREENSHOT_DIR.join("proof-#{name}.png"))
  end
end
