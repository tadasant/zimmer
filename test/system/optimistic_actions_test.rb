require "application_system_test_case"
require "mocha/minitest"

# The page shows a mutation at the click and asks the server after; a refusal puts
# it back. Only a browser can prove the "at the click" half, so these hold the
# server's answer back — `window.fetch` is replaced for one path with a promise
# that never settles, or one that rejects — and look at the page before any answer
# could have arrived.
class OptimisticActionsTest < ApplicationSystemTestCase
  SCREENSHOT_DIR = Rails.root.join("tmp", "capybara")

  test "trashing a card takes it off the board at the click, before the server answers" do
    session = sessions(:failed)
    visit root_path(every_status_params(view: SessionsController::VIEW_MODE_CREATED_DESC))
    assert_selector "turbo-frame#session_#{session.id}"
    hold_fetch_for("/sessions/#{session.id}/archive")

    within("turbo-frame#session_#{session.id}") { click_on "Trash" }

    # The server has not answered — and never will — yet the card is gone.
    assert_no_selector "turbo-frame#session_#{session.id}", wait: 2
    assert_no_selector "#flash", text: "could not be moved"
    capture("trash-at-the-click")
  end

  test "a trash the server refuses puts the card back with the refusal" do
    session = sessions(:failed)
    visit root_path(every_status_params(view: SessionsController::VIEW_MODE_CREATED_DESC))
    assert_selector "turbo-frame#session_#{session.id}"
    reject_fetch_for("/sessions/#{session.id}/archive")

    within("turbo-frame#session_#{session.id}") { click_on "Trash" }

    assert_selector "turbo-frame#session_#{session.id}", wait: 5
    assert_selector "#flash [data-client-toast='alert']", text: "could not be moved to trash"
    assert_not session.reload.archived?, "nothing reached the server"
    capture("trash-put-back")
  end

  test "a trash refused over queued messages comes back with Archive anyway" do
    session = sessions(:failed)
    session.enqueued_messages.create!(content: "still queued", position: 1, status: "pending")
    visit root_path(every_status_params(view: SessionsController::VIEW_MODE_CREATED_DESC))
    assert_selector "turbo-frame#session_#{session.id}"

    within("turbo-frame#session_#{session.id}") { click_on "Trash" }

    # The server's 422 puts the card back; its own alert carries the speed bump.
    assert_selector "#flash", text: "Archive anyway"
    assert_selector "turbo-frame#session_#{session.id}"
    assert_not session.reload.archived?
    capture("trash-archive-anyway")
  end

  test "hiding a card takes it off the board at the click" do
    session = sessions(:failed)
    visit root_path(every_status_params(view: SessionsController::VIEW_MODE_CREATED_DESC))
    assert_selector "turbo-frame#session_#{session.id}"
    hold_fetch_for("/sessions/#{session.id}/update_visibility")

    within("turbo-frame#session_#{session.id}") do
      find("[data-controller~='overflow-menu'] button").click
      click_on "Hide"
    end

    assert_no_selector "turbo-frame#session_#{session.id}", wait: 2
    capture("hide-at-the-click")
  end

  test "the Quick Router keeps the board and follows the new session in a toast" do
    page.driver.browser.manage.window.resize_to(1400, 900)
    AgentSessionJob.stubs(:enqueue_new_session)
    visit root_path
    assert_selector "[data-quick-prompt-target='textarea']"
    board_path = current_path

    textarea = find("[data-quick-prompt-target='textarea']")
    textarea.fill_in(with: "Rotate the staging deploy key")
    textarea.send_keys([ :control, :enter ])

    assert_selector "#flash [data-client-toast='notice']", text: /Started session #\d+ — queued for a worker/, wait: 10
    session = Session.order(:created_at).last
    assert_equal "Rotate the staging deploy key", session.prompt
    assert_equal board_path, current_path, "the board stays on screen"
    assert_equal "", find("[data-quick-prompt-target='textarea']").value, "the box is ready for the next request"
    within("#flash") { assert_link "Open session", href: session_path(session) }
    capture("quick-router-toast-queued")

    # The toast follows the session as it moves on.
    session.update_columns(
      status: Session.statuses[:running],
      title: "Rotate the staging deploy key",
      metadata: session.metadata.except("auto_generated_title")
    )
    assert_selector "#flash [data-client-toast='notice']",
      text: "Session ##{session.id} · Rotate the staging deploy key — running.", wait: 10
    assert_equal board_path, current_path
    capture("quick-router-toast-running")

    # Out of the queue, the toast stops following and goes away on its own.
    assert_no_selector "#flash [data-client-toast='notice']", wait: 15
  end

  test "a Quick Router start the server refuses with a reason shows that reason" do
    page.driver.browser.manage.window.resize_to(1400, 900)
    visit root_path
    assert_selector "[data-quick-prompt-target='textarea']"
    long_prompt = "x" * (Session::PROMPT_MAX_LENGTH + 1)
    page.execute_script("document.querySelector(\"[data-quick-prompt-target='textarea']\").value = arguments[0]", long_prompt)

    find("[data-quick-prompt-target='textarea']").send_keys([ :control, :enter ])

    assert_selector "#flash [data-client-toast='alert']", text: "Prompt is too long", wait: 10
    assert_equal long_prompt.length, find("[data-quick-prompt-target='textarea']").value.length
  end

  test "a Quick Router start the server refuses keeps the words in the box" do
    page.driver.browser.manage.window.resize_to(1400, 900)
    visit root_path
    assert_selector "[data-quick-prompt-target='textarea']"
    board_path = current_path
    reject_fetch_for("/sessions/quick_prompt")

    find("[data-quick-prompt-target='textarea']").fill_in(with: "Rotate the staging deploy key")
    find("[data-quick-prompt-target='textarea']").send_keys([ :control, :enter ])

    assert_selector "#flash [data-client-toast='alert']", text: "The session did not start: The server could not be reached.", wait: 5
    assert_no_selector "#flash [data-client-toast='notice']"
    assert_equal board_path, current_path
    assert_equal "Rotate the staging deploy key", find("[data-quick-prompt-target='textarea']").value
    capture("quick-router-refused")
  end

  test "dismissing a read notification takes its row away at the click" do
    notification = notifications(:default_notification)
    notification.update!(read: true)
    visit notifications_path
    assert_selector "#notification_#{notification.id}"
    hold_fetch_for("/notifications/#{notification.id}/dismiss")

    within("#notification_#{notification.id}") { click_on "Dismiss notification" }

    assert_no_selector "#notification_#{notification.id}", wait: 2
    assert Notification.exists?(notification.id), "nothing reached the server"
  end

  test "a follow-up shows under the conversation at the click" do
    session = sessions(:needs_input)
    visit session_path(session)
    assert_selector "textarea[name='follow_up_prompt']"
    hold_fetch_for("/sessions/#{session.id}/follow_up")

    fill_in "follow_up_prompt", with: "Yes, merge it."
    find("textarea[name='follow_up_prompt']").send_keys([ :control, :enter ])

    assert_selector "[data-pending-user-message]", text: "Yes, merge it.", wait: 2
    assert_selector "[data-pending-state]", text: "Sending…"
    capture("follow-up-at-the-click")
  end

  private

  # Turbo and the controllers go through `window.fetch`; a request to `path` never
  # settles, so whatever the page shows afterwards, it showed without an answer.
  def hold_fetch_for(path)
    page.execute_script(<<~JS, path)
      const path = arguments[0]
      const real = window.fetch
      window.fetch = (resource, options) => {
        const url = typeof resource === "string" ? resource : resource.url
        if (url.includes(path)) return new Promise(() => {})
        return real.call(window, resource, options)
      }
    JS
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
    page.execute_script("window.scrollTo(0, 0)")
    page.save_screenshot(SCREENSHOT_DIR.join("proof-#{name}.png"))
  end
end
