# frozen_string_literal: true

require "application_system_test_case"

# When BroadcastService's circuit breaker opens, Turbo Stream broadcasts are
# dropped for 60 seconds and every page silently stops updating. Before this
# banner the UI looked fine throughout — a frozen dashboard is indistinguishable
# from a quiet one, so the user waits on a page that will never move (#86).
class LiveUpdatesBannerTest < ApplicationSystemTestCase
  teardown do
    BroadcastService.new.reset_circuit_breaker
  end

  test "no banner while broadcasts are flowing" do
    visit root_url

    assert_selector "h1", text: "Agent Sessions"
    assert_no_text "Live updates paused"
  end

  test "the dashboard says so when live updates are paused" do
    open_circuit_breaker

    visit root_url

    assert_text "Live updates paused"
    assert_text "Your sessions keep running"
  end

  test "the session page says so when live updates are paused" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Paused broadcasts session",
      status: :running
    )
    open_circuit_breaker

    visit session_path(session)

    assert_text "Live updates paused"
  end

  # The banner is polled, not broadcast — a breaker that opens while the user is
  # sitting on a page they will not reload is the whole point. Poll at the
  # controller rather than waiting out the interval, which is what the interval
  # would otherwise cost every run.
  test "the banner appears and clears without a page reload" do
    visit root_url
    assert_no_text "Live updates paused"

    open_circuit_breaker
    poll_live_updates_status
    assert_text "Live updates paused"

    BroadcastService.new.reset_circuit_breaker
    poll_live_updates_status
    assert_no_text "Live updates paused"

    # Still the same page load — nothing navigated.
    assert_current_path root_path
  end

  private

  def open_circuit_breaker
    BroadcastService.circuit_breaker_failures = BroadcastService::CIRCUIT_BREAKER_THRESHOLD
    BroadcastService.circuit_breaker_opened_at = Time.current
  end

  # Drive one poll immediately instead of waiting for the controller's interval.
  def poll_live_updates_status
    page.execute_script(<<~JS)
      (() => {
        const el = document.querySelector('[data-controller~="live-updates-status"]');
        const ctrl = window.Stimulus.getControllerForElementAndIdentifier(el, 'live-updates-status');
        ctrl.poll();
      })();
    JS
  end
end
