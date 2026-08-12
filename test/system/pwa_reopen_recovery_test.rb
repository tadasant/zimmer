require "application_system_test_case"

# Reopening the installed PWA must not reload the session screen.
#
# iOS fires `pageshow` with `persisted: true` every time a backgrounded
# standalone PWA is restored from bfcache — which is to say, every time the user
# reopens the app. stream_visibility_recovery_controller.js used to treat that
# event alone as proof of a dead ActionCable socket and reload, so every reopen
# rebuilt the document and threw away scroll position, collapsed panels, and
# everything else the user had accumulated on screen.
#
# It now checks whether the socket is actually dead first. These tests pin both
# sides of that check, and — because the reload exists to protect against a
# silently frozen page — that a genuinely dead socket still gets the page back to
# a live, current state.
#
# Turbo's own events are the discriminator: `turbo:visit` fires when a visit is
# issued at all, so an empty event log is proof that nothing navigated.
class PwaReopenRecoveryTest < ApplicationSystemTestCase
  def create_session(status: :running)
    Session.create!(
      prompt: "Initial prompt",
      status: status,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
  end

  def instrument_page
    page.execute_script(<<~JS)
      window.__zimmerEvents = []
      for (const name of ["turbo:visit", "turbo:render"]) {
        document.addEventListener(name, () => window.__zimmerEvents.push(name))
      }
    JS
  end

  def recorded_events
    page.evaluate_script("window.__zimmerEvents || []")
  end

  # Stimulus reads values off the attribute each time, so a test can shorten the
  # controller's windows without waiting out the real ones.
  def tune_recovery(stale_after:, reconnect_grace: 100)
    page.execute_script(<<~JS)
      const el = document.querySelector("[data-controller~='stream-visibility-recovery']")
      el.setAttribute("data-stream-visibility-recovery-stale-after-value", "#{stale_after}")
      el.setAttribute("data-stream-visibility-recovery-reconnect-grace-value", "#{reconnect_grace}")
    JS
  end

  # The bfcache restore iOS performs when a standalone PWA is reopened.
  def reopen_from_bfcache
    page.execute_script(<<~JS)
      window.dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true }))
    JS
  end

  # Shadowing `visibilityState` is deleted again afterwards, restoring the
  # prototype getter — left in place it would pin the document to "visible" for
  # the rest of the page's life and quietly break any later cycle.
  def hide_then_show
    page.execute_script(<<~JS)
      Object.defineProperty(document, "visibilityState", { value: "hidden", configurable: true })
      document.dispatchEvent(new Event("visibilitychange"))
      Object.defineProperty(document, "visibilityState", { value: "visible", configurable: true })
      document.dispatchEvent(new Event("visibilitychange"))
      delete document.visibilityState
    JS
  end

  # Count calls to the consumer's own reopen(), which is what actually restores
  # live updates. Without this the reopen step is untested: a Turbo visit rebuilds
  # the stream sources anyway, so the page would come back live either way.
  def spy_on_reopen
    page.execute_script(<<~JS)
      const connection = document.querySelector("turbo-cable-stream-source").subscription.consumer.connection
      window.__reopenCalls = 0
      const original = connection.reopen.bind(connection)
      connection.reopen = function () { window.__reopenCalls += 1; return original() }
    JS
  end

  def reopen_calls
    page.evaluate_script("window.__reopenCalls || 0")
  end

  # Close the WebSocket out from under ActionCable the way a suspended OS does,
  # so `connection.isOpen()` reports what it reports on a real reopen.
  def kill_cable_socket
    page.execute_script(<<~JS)
      document.querySelector("turbo-cable-stream-source").subscription.consumer.connection.webSocket.close()
    JS
  end

  def wait_for_event(name, timeout: 8)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until recorded_events.include?(name)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end
    true
  end

  # After the recovery re-renders, the page's subscriptions are torn down and
  # rebuilt. Broadcasting before that has settled races the handshake and the
  # message is dropped — ActionCable does not queue for late subscribers — so
  # wait for the render, let the new sources mount, then wait on them.
  def wait_for_reloaded_page_to_go_live
    assert wait_for_event("turbo:render"), "the recovery never finished re-rendering"
    sleep 1
    wait_for_turbo_streams_connected(timeout: 15)
  end

  test "reopening the PWA with a live socket does not navigate at all" do
    # The regression itself. Before the fix this produced a turbo:visit every
    # single time, which is what made the PWA reload on every reopen.
    session = create_session
    visit session_path(session)
    wait_for_turbo_streams_connected

    tune_recovery(stale_after: 0)
    instrument_page

    reopen_from_bfcache

    # Long enough that a reload would have been issued and rendered.
    sleep 1.5

    assert_empty recorded_events,
      "reopening the PWA reloaded the page even though the cable was still connected"

    # The reload existed to keep the page live. It has to still be live.
    session.update!(status: :needs_input)
    assert_selector "[id='session_#{session.id}_status_badge']", text: "Needs Input", wait: 5
  end

  test "a brief hide is ignored" do
    session = create_session
    visit session_path(session)
    wait_for_turbo_streams_connected

    # The real 5s window. Kill the socket first so this pins the duration gate
    # specifically: with a live socket the later isOpen() check would keep the
    # page still anyway, and the test would pass with the gate deleted.
    tune_recovery(stale_after: 5000)
    instrument_page
    kill_cable_socket

    hide_then_show
    sleep 1.5

    assert_empty recorded_events,
      "a hide shorter than staleAfter reloaded the page"
  end

  test "returning visible with a live socket does not navigate either" do
    session = create_session
    visit session_path(session)
    wait_for_turbo_streams_connected

    tune_recovery(stale_after: 0)
    instrument_page

    hide_then_show
    sleep 1.5

    assert_empty recorded_events,
      "a long hide reloaded the page even though the cable survived it"
  end

  test "a socket that really died is reloaded and comes back live" do
    session = create_session
    visit session_path(session)
    wait_for_turbo_streams_connected

    tune_recovery(stale_after: 0)
    instrument_page
    spy_on_reopen

    kill_cable_socket
    reopen_from_bfcache

    assert wait_for_event("turbo:visit"),
      "a reopen with a dead cable left the page stale instead of re-rendering it"

    # `pageshow` alone does not trip ActionCable's own visibility monitor, so
    # this call can only have come from the controller.
    assert_equal 1, reopen_calls,
      "the controller did not reopen the consumer, so live updates depended entirely on the re-render"

    # And the point of all of it: updates broadcast from the server land in the
    # DOM again afterwards.
    wait_for_reloaded_page_to_go_live
    session.update!(status: :needs_input)
    assert_selector "[id='session_#{session.id}_status_badge']", text: "Needs Input", wait: 15
  end

  test "a socket found dead on becoming visible is recovered the same way" do
    session = create_session
    visit session_path(session)
    wait_for_turbo_streams_connected

    tune_recovery(stale_after: 0)
    instrument_page

    kill_cable_socket
    hide_then_show

    assert wait_for_event("turbo:visit"),
      "a stale visibility return left the page stale instead of re-rendering it"

    wait_for_reloaded_page_to_go_live
    session.update!(status: :needs_input)
    assert_selector "[id='session_#{session.id}_status_badge']", text: "Needs Input", wait: 15
  end
end
