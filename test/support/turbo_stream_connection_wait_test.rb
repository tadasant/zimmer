# frozen_string_literal: true

require "test_helper"
require "capybara"
require "turbo/system_test_helper"
require "application_system_test_case"
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

  # Both ceilings are set relative to a number that lives in the application, not
  # here, so read it from the application rather than restating it: a controller
  # that starts allowing a source longer than the harness waits puts every `visit`
  # back on the wrong side of the race.
  test "both ceilings outlast the reconnect grace the application itself allows" do
    controller = Rails.root.join("app/javascript/controllers/cable_reconnect_controller.js").read
    grace_ms = controller[/grace:\s*\{\s*type:\s*Number,\s*default:\s*(\d+)/, 1]

    assert grace_ms, "could not read the cable-reconnect grace; the ceilings below are unanchored"

    first_resubscribe = grace_ms.to_i / 1000.0

    assert_operator TurboStreamConnectionWait::POST_VISIT_TIMEOUT, :>, first_resubscribe,
      "the post-visit ceiling expires before the page has re-subscribed even once"
    assert_operator TurboStreamConnectionWait::TIMEOUT, :>, first_resubscribe * 3,
      "the explicit ceiling should cover the second re-subscribe (grace doubles) as well as the first"
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
  # keys — and every lenient way of reading it rounds toward "nothing is pending".
  # `nil.to_i` is 0 and `Array(nil)` is `[]`, so a renamed key or a symbolized Hash
  # would turn the whole wait into a silent pass with a green suite. Reject it.
  [
    [ "a symbolized reading", { total: 2, pending: [ "session_1_status" ] } ],
    [ "a renamed key", { "total" => 2, "unconnected" => [ "session_1_status" ] } ],
    [ "a null pending list", { "total" => 2, "pending" => nil } ],
    [ "no reading at all", nil ]
  ].each do |description, malformed|
    test "#{description} is refused rather than read as connected" do
      probe = readings(malformed)

      error = assert_raises(Capybara::ExpectationNotMet) do
        TurboStreamConnectionWait.wait(timeout: 0, poll_interval: 0, &probe)
      end

      assert_includes error.message, "expected a reading"
    end
  end

  # The block talks to a browser, and a browser can refuse — an open alert, a
  # closed window. Nothing here can answer that, so it propagates on the first
  # occurrence rather than being retried for the whole timeout.
  test "an error from the browser propagates instead of being polled over" do
    calls = 0

    assert_raises(Selenium::WebDriver::Error::UnexpectedAlertOpenError) do
      TurboStreamConnectionWait.wait(poll_interval: 0) do
        calls += 1
        raise Selenium::WebDriver::Error::UnexpectedAlertOpenError, "alert open"
      end
    end

    assert_equal 1, calls
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

    assert_equal ApplicationSystemTestCase,
      ApplicationSystemTestCase.instance_method(:connect_turbo_cable_stream_sources).owner,
      "the override is gone; every `visit` is back on turbo-rails' cached-handle wait"
  end

  # turbo-rails declares `(**options, &block)`. The override refuses filters rather
  # than ignoring them, but it has to *accept* them or a release that starts
  # passing one would raise ArgumentError out of every `visit` in the suite.
  test "the override absorbs the signature turbo-rails declares" do
    assert_equal [ [ :keyrest, :options ], [ :block, :block ] ],
      Turbo::SystemTestHelper.instance_method(:connect_turbo_cable_stream_sources).parameters

    assert_equal [ [ :keyrest, :options ], [ :block, :block ] ],
      ApplicationSystemTestCase.instance_method(:connect_turbo_cable_stream_sources).parameters
  end

  # The script is what the poll's freshness rests on: it must read the document
  # every time rather than close over a node list.
  test "the reading script queries the document and reports the connected attribute" do
    assert_includes TurboStreamConnectionWait::READING_SCRIPT,
      "document.querySelectorAll('turbo-cable-stream-source')"
    assert_includes TurboStreamConnectionWait::READING_SCRIPT, "hasAttribute('connected')"
  end
end
