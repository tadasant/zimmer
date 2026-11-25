# frozen_string_literal: true

require "application_system_test_case"

# What one system test may not hand to the next.
class BrowserIsolationTest < ApplicationSystemTestCase
  # Far longer than the reset takes to leave the page and clear the cookies, so the
  # response is still on its way through both.
  RESPONSE_TIME = 2

  # How long after the reset a cookie is still looked for. Capybara's reset waits
  # for the app to have answered, which is a moment before the browser has read it.
  SETTLE_TIME = 1

  PATH = "/?filters=1&visibility=all"

  def filters_cookie?
    page.driver.browser.execute_cdp("Network.getAllCookies")["cookies"]
      .any? { |cookie| cookie["name"] == SessionsController::FILTERS_COOKIE.to_s }
  end

  test "a request still in flight at the reset does not set a cookie after it" do
    visit root_path
    page.evaluate_async_script("const done = arguments[0]; fetch('#{PATH}').then(() => done(true))")
    assert filters_cookie?, "the request sets no cookie, so there is nothing here to leak"

    arrived = Queue.new
    slow = ->(_name, _start, _finish, _id, payload) do
      next unless payload[:path] == PATH

      arrived << true
      sleep RESPONSE_TIME
    end

    ActiveSupport::Notifications.subscribed(slow, "start_processing.action_controller") do
      page.execute_script("fetch('#{PATH}')")
      assert arrived.pop(timeout: 10), "the request never reached the server"
      Capybara.reset_sessions!
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SETTLE_TIME
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      assert_not filters_cookie?, "the response set the filters cookie after the reset cleared it"
      sleep 0.05
    end
  end
end
