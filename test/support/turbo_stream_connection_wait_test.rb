# frozen_string_literal: true

require "test_helper"
require "capybara"
require "turbo/system_test_helper"
require_relative "turbo_stream_connection_wait"

# Pins the properties the browser suite cannot demonstrate on demand: that the
# post-`visit` readiness check re-reads the document on every tick instead of
# waiting on one element, and that it waits past the application's own reconnect
# grace before it gives up.
#
# The race itself is not reproducible to order — it needs an ActionCable handshake
# to run long on a loaded CI runner — so it is asserted here, on the wait, rather
# than by running the flaky test until it loses again.
class TurboStreamConnectionWaitTest < ActiveSupport::TestCase
  # Every reading is a fresh look at the document, which is the whole point: a
  # source the page replaced mid-wait shows up as the next reading rather than as
  # a handle that can never match again.
  def readings(*scripted)
    queue = scripted.dup
    @taken = 0
    lambda do
      @taken += 1
      queue.length > 1 ? queue.shift : queue.first
    end
  end

  def reading(total:, pending: [])
    { "total" => total, "pending" => pending }
  end

  test "returns as soon as every source reports connected" do
    probe = readings(reading(total: 3, pending: []))

    TurboStreamConnectionWait.wait(&probe)

    assert_equal 1, @taken, "a healthy page should cost exactly one reading"
  end

  test "keeps re-reading the document until the pending sources connect" do
    probe = readings(
      reading(total: 3, pending: %w[timeline status elicitations]),
      reading(total: 3, pending: %w[elicitations]),
      reading(total: 3, pending: [])
    )

    TurboStreamConnectionWait.wait(poll_interval: 0, &probe)

    assert_equal 3, @taken
  end

  # The regression this exists for. turbo-rails resolves the unconnected sources
  # once and then asserts that *those handles* gained `[connected]`; when
  # cable_reconnect_controller.js re-subscribes a source by replacing it, the
  # element the assertion is holding is gone and the wait can never succeed. A
  # poll that re-reads the document sees the replacement connect and returns.
  test "a source replaced mid-wait is observed through the replacement" do
    probe = readings(
      reading(total: 1, pending: %w[session_1_status]),
      # cable-reconnect detaches and re-attaches the element: same channel, new node.
      reading(total: 1, pending: %w[session_1_status]),
      reading(total: 1, pending: [])
    )

    assert_nothing_raised do
      TurboStreamConnectionWait.wait(poll_interval: 0, &probe)
    end
  end

  test "waits past the reconnect grace the application itself allows" do
    grace_ms = 3000 # cable_reconnect_controller.js: graceValue default

    assert_operator TurboStreamConnectionWait::TIMEOUT, :>, grace_ms / 1000.0,
      "a ceiling below the app's own re-subscribe delay reports a failure the page was still fixing"
  end

  test "raises naming the channels still pending" do
    probe = readings(reading(total: 3, pending: %w[session_1_status session_1_elicitations]))

    error = assert_raises(Capybara::ExpectationNotMet) do
      TurboStreamConnectionWait.wait(timeout: 0, poll_interval: 0, &probe)
    end

    assert_includes error.message, "2 of 3 still pending"
    assert_includes error.message, "session_1_status"
    assert_includes error.message, "session_1_elicitations"
  end

  # The `visit` wrapper runs on every page in the suite, most of which broadcast
  # nothing. Waiting there would add the full timeout to hundreds of navigations.
  test "a page with no stream sources is not something to wait for" do
    probe = readings(reading(total: 0))

    TurboStreamConnectionWait.wait(timeout: 0, poll_interval: 0, &probe)

    assert_equal 1, @taken
  end

  # ...but a test that asked for the wait explicitly is about to trigger a
  # broadcast, so a page with no subscriber is a failure, not a fast pass.
  test "an explicit wait fails loudly when no source ever appears" do
    probe = readings(reading(total: 0))

    error = assert_raises(Capybara::ExpectationNotMet) do
      TurboStreamConnectionWait.wait(timeout: 0, poll_interval: 0, require_source: true, &probe)
    end

    assert_includes error.message, "no <turbo-cable-stream-source> appeared"
  end

  # The reading crosses the browser boundary as JSON, so it arrives with String
  # keys. Both callers hand it over untouched.
  test "reads the shape evaluate_script actually returns" do
    probe = readings({ "total" => 2, "pending" => [ "session_1_status" ] })

    error = assert_raises(Capybara::ExpectationNotMet) do
      TurboStreamConnectionWait.wait(timeout: 0, poll_interval: 0, &probe)
    end

    assert_includes error.message, "1 of 2 still pending"
  end

  # ApplicationSystemTestCase overrides turbo-rails' own readiness check by name.
  # If turbo-rails renames the method or stops calling it after `visit`, the
  # override silently stops applying and the flake comes back with no test to
  # catch it — so pin the seam here, where it costs no browser.
  test "turbo-rails still routes its post-visit readiness check through the method we override" do
    assert_includes Turbo::SystemTestHelper.instance_methods, :connect_turbo_cable_stream_sources,
      "ApplicationSystemTestCase#connect_turbo_cable_stream_sources overrides a method that no longer exists"

    assert_includes Rails.application.config.turbo.test_connect_after_actions, :visit,
      "turbo-rails no longer runs the readiness check after `visit`; the override covers nothing"
  end

  # The script is what the poll's freshness rests on: it must read the document
  # every time rather than close over a node list.
  test "the reading script queries the document and reports the connected attribute" do
    assert_includes TurboStreamConnectionWait::READING_SCRIPT,
      "document.querySelectorAll('turbo-cable-stream-source')"
    assert_includes TurboStreamConnectionWait::READING_SCRIPT, "hasAttribute('connected')"
  end
end
