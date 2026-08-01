# frozen_string_literal: true

require "test_helper"

# The endpoint behind the "live updates paused" banner (#86). It is polled over
# plain HTTP on purpose: the state it reports is Turbo Stream broadcasting being
# down, so broadcasting the banner is not an option.
class LiveUpdatesControllerTest < ActionDispatch::IntegrationTest
  teardown do
    BroadcastService.new.reset_circuit_breaker
  end

  test "renders an empty fragment while broadcasts are flowing" do
    get live_updates_status_path

    assert_response :success
    assert_no_match(/Live updates paused/, response.body)
    assert_equal "", response.body.strip
  end

  test "renders the banner while the circuit breaker is open" do
    BroadcastService.circuit_breaker_opened_at = Time.current

    get live_updates_status_path

    assert_response :success
    assert_match(/Live updates paused/, response.body)
    # The banner has to say what it means: the page is frozen, the sessions are
    # not, and it will clear itself.
    assert_match(/stopped updating/, response.body)
    assert_match(/sessions keep running/, response.body)
    assert_match(/resume automatically/, response.body)
  end

  test "stops rendering the banner once the reset window has elapsed" do
    BroadcastService.circuit_breaker_opened_at =
      Time.current - (BroadcastService::CIRCUIT_BREAKER_RESET_TIME + 1)

    get live_updates_status_path

    assert_response :success
    assert_no_match(/Live updates paused/, response.body)
  end

  test "the fragment is served without the application layout" do
    BroadcastService.circuit_breaker_opened_at = Time.current

    get live_updates_status_path

    assert_response :success
    assert_no_match(/<html/, response.body, "the poller swaps this straight into the DOM")
  end
end
