# frozen_string_literal: true

require "capybara"

# Waiting for `<turbo-cable-stream-source>` to connect, without holding an element
# handle across the wait.
#
# Why this exists
# ---------------
# turbo-rails wraps `visit` on every system test — `config.turbo
# .test_connect_after_actions` defaults to `%i[visit]`, and its engine defines
# `def visit(...) = super.tap { connect_turbo_cable_stream_sources }` on
# `ActionDispatch::SystemTestCase`. So its readiness check runs after every
# navigation in the whole browser suite, before a single line of the test body.
#
# Its implementation resolves the unconnected sources **once**, then waits on each
# resolved handle:
#
#   all(:turbo_cable_stream_source, connected: false, wait: 0).each do |element|
#     element.assert_matches_selector(:turbo_cable_stream_source, connected: true)
#   end
#
# `assert_matches_selector` re-runs the query against the document and asserts the
# handle it is holding is in the result — `raise Capybara::ExpectationNotMet,
# 'Item does not match the provided selector' unless result.include? self`. Two
# things follow from that, and both bite here.
#
# **The wait is only as long as `Capybara.default_max_wait_time`**, which this repo
# leaves at Capybara's 2-second default. The app's own `cable-reconnect` controller
# treats a source as merely slow until `grace` (3000ms) has passed, and backs off
# exponentially from there. A harness that gives up at 2s expires *before* the
# application has made its first re-subscribe attempt — it is not waiting long
# enough to observe the recovery the page is built around.
#
# **The wait is pinned to one element object.** `cable-reconnect` re-subscribes a
# stuck source by `replaceWith`-ing it out of the document and back in; a Turbo
# Stream or a frame swap can replace the subtree outright. Either way the identity
# check is asking about a node the page has moved on from, so the wait cannot
# succeed no matter how long it runs — it burns the full timeout and raises.
#
# Both failures surface identically, in `visit`, with a message that names neither
# Turbo nor ActionCable:
#
#   Capybara::ExpectationNotMet: Item does not match the provided selector
#       test/application_system_test_case.rb:196:in 'ApplicationSystemTestCase#visit'
#
# That is [run 33949817772](https://github.com/tadasant/zimmer/actions/runs/33949817772),
# where `QueuedMessagesWorkflowTest#test_deleting_message_updates_remaining_message_positions`
# errored on its `visit` — on a commit that touched nothing near queued messages,
# with a failure screenshot showing the page fully rendered.
#
# What this does instead
# ----------------------
# Poll the *document* for the condition rather than holding an element: re-read the
# set of sources on every tick, so a source the page replaced mid-wait is simply
# the next reading rather than a wait that can never be satisfied. And give it a
# timeout above the application's own reconnect backoff, so a slow handshake is
# waited out rather than raced.
#
# Kept separate from `ApplicationSystemTestCase` so it can be tested without a
# browser: `wait` takes the reading as a block, and the unit test drives it with a
# fake that returns scripted readings.
module TurboStreamConnectionWait
  # Long enough to cover the application's own recovery rather than expiring
  # inside it: `cable_reconnect_controller.js` waits `grace` (3s) before its first
  # re-subscribe and doubles from there, so a shorter ceiling reports a failure the
  # page was still in the middle of fixing. Nothing pays this cost when the cable
  # is healthy — the poll returns on its first reading.
  TIMEOUT = 10

  # Read every `<turbo-cable-stream-source>` in the document and report which of
  # them Turbo has not yet marked `connected`.
  #
  # `page.evaluate_script` goes straight to the driver rather than through the
  # document node, so — unlike a Capybara element query — it cannot itself observe
  # a detached node while the page re-renders underneath it.
  READING_SCRIPT = <<~JS
    (function () {
      const sources = Array.from(document.querySelectorAll('turbo-cable-stream-source'));
      return {
        total: sources.length,
        pending: sources
          .filter((el) => !el.hasAttribute('connected'))
          .map((el) => el.getAttribute('channel') || el.getAttribute('signed-stream-name') || 'unnamed')
      };
    })()
  JS

  POLL_INTERVAL = 0.05

  # Block until no source is pending, then return.
  #
  # `require_source` is what separates the two callers. A test that calls
  # `wait_for_turbo_streams_connected` explicitly is about to trigger a broadcast
  # and depends on a subscriber existing, so a page with no sources at all is a
  # failure worth raising — otherwise the test passes for the wrong reason. The
  # `visit` wrapper runs on every page in the suite, most of which broadcast
  # nothing, so for it an empty page is simply nothing to wait for.
  #
  # Raises Capybara::ExpectationNotMet, naming the channels still pending, so the
  # failure says which subscription was missing rather than which element object
  # went stale.
  def self.wait(timeout: TIMEOUT, require_source: false, poll_interval: POLL_INTERVAL)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    reading = nil

    loop do
      reading = normalize(yield)

      return if satisfied?(reading, require_source:)
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep poll_interval
    end

    raise Capybara::ExpectationNotMet, failure_message(reading, timeout:)
  end

  def self.satisfied?(reading, require_source:)
    return false if reading[:total].zero? && require_source

    reading[:pending].empty?
  end
  private_class_method :satisfied?

  # `evaluate_script` hands back a Hash with String keys; the unit test drives the
  # same shape. Normalizing here keeps both callers honest without either of them
  # knowing which side produced the reading.
  def self.normalize(reading)
    { total: reading["total"].to_i, pending: Array(reading["pending"]) }
  end
  private_class_method :normalize

  def self.failure_message(reading, timeout:)
    return "no <turbo-cable-stream-source> appeared within #{timeout}s" if reading[:total].zero?

    "Turbo Stream subscriptions did not connect within #{timeout}s: " \
      "#{reading[:pending].size} of #{reading[:total]} still pending (#{reading[:pending].join(', ')})"
  end
  private_class_method :failure_message
end
