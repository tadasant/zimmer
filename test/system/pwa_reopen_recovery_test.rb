require "application_system_test_case"

# Reopening the installed PWA must not reload the session screen.
#
# iOS suspends a backgrounded standalone PWA. The process stops, the ActionCable
# WebSocket dies with it, and the page comes back through the back/forward cache
# — `pageshow` with `persisted: true`. So on a real reopen the socket is *always*
# dead, and a recovery keyed on "is the socket dead?" runs its dead-socket branch
# every single time the user switches back to the app. Answering that branch with
# a replacing `Turbo.visit` is what makes the app appear to reload on each
# reopen; checking `isOpen()` in front of it does not help, because it only
# covers the case that never happens.
#
# The branch backfills instead — fetch the page the server would render and
# reconcile the regions broadcasts target, in place. These tests pin the
# dead-socket case in particular, because that is the one a phone performs:
#
#   - nothing navigates (`turbo:visit` never fires, and the document is the same
#     document — a sentinel written onto <body> survives),
#   - what the server broadcast while the socket was dead is on screen, exactly
#     once,
#   - and the page is live again afterwards.
#
# The socket-alive branch is pinned below too, but it is the cheap case.
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
      window.__zimmerRecovered = []
      document.addEventListener("stream-visibility-recovery:recovered", (event) => {
        window.__zimmerRecovered.push(event.detail)
      })
      // A replacing Turbo visit swaps <body>, so an attribute set on it here is
      // gone if — and only if — the page navigated. This is what distinguishes a
      // backfill from a re-render that happens to produce the same content.
      document.body.setAttribute("data-reopen-sentinel", "alive")
    JS
  end

  def recorded_events
    page.evaluate_script("window.__zimmerEvents || []")
  end

  def recoveries
    page.evaluate_script("window.__zimmerRecovered || []")
  end

  # Duplication is the failure mode a text assertion cannot see: two copies of a
  # row satisfy `assert_selector text:` just as happily as one.
  def timeline_row_count(session)
    page.evaluate_script(
      "document.querySelectorAll('#session_#{session.id}_timeline > [data-timeline-item]').length"
    )
  end

  def same_document?
    page.evaluate_script("document.body.getAttribute('data-reopen-sentinel') === 'alive'")
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
  #
  # Selenium cannot drive a real back/forward-cache restore, so the event is
  # dispatched by hand. What this suite pins is the state the controller finds
  # when it runs — a genuinely closed socket, killed below — not which listener
  # woke it.
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
  # live updates.
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
  # and forbid the reconnect its own monitor would otherwise perform — on a real
  # reopen the socket is dead for the whole time the app was away.
  def kill_cable_socket
    page.execute_script(<<~JS)
      document.querySelectorAll("turbo-cable-stream-source").forEach((source) => {
        source.subscription.consumer.connection.close({ allowReconnect: false })
      })
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

  def wait_for_recovery(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while recoveries.empty?
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end
    true
  end

  # Settle on whichever answer the reopen produced — a backfill that reported
  # itself, or a navigation. Waiting only for the former would report a reload as
  # a timeout, which reads as a flaky test rather than as the regression it is.
  def wait_for_reopen_to_settle(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while recoveries.empty? && recorded_events.empty?
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end
  end

  # THE REGRESSION. On `main` this fails on the very first assertion: the
  # dead-socket branch issues `Turbo.visit(href, { action: "replace" })`, so
  # `turbo:visit` fires and the <body> sentinel is gone.
  test "reopening the PWA with a dead socket recovers in place instead of reloading" do
    session = create_session
    visit session_path(session, filter: "verbose")
    wait_for_turbo_streams_connected

    # Something the reader accumulated on screen, which a reload would destroy.
    page.execute_script("document.querySelector('details[data-controller~=\"transcript-panel\"]').open = true")

    tune_recovery(stale_after: 0)
    instrument_page
    spy_on_reopen

    kill_cable_socket

    # Broadcast into a socket that is not there. This is the content the reopen
    # has to recover: re-subscribing cannot replay it.
    Log.create!(session: session, level: "info", content: "MISSED WHILE BACKGROUNDED")
    session.update!(status: :needs_input)

    reopen_from_bfcache
    wait_for_reopen_to_settle

    assert same_document?,
      "reopening the PWA reloaded the page — the document the reader was looking at was replaced"
    assert_empty recorded_events,
      "reopening the PWA navigated (#{recorded_events.inspect}) instead of backfilling in place"

    # The disclosure the reader opened is still open, which is the whole point.
    assert page.evaluate_script("document.querySelector('details[data-controller~=\"transcript-panel\"]').open"),
      "the recovery collapsed a panel the reader had opened"

    # And the content that was broadcast into the dead socket is on screen.
    assert_selector "#session_#{session.id}_timeline", text: "MISSED WHILE BACKGROUNDED", wait: 5
    assert_selector "#session_#{session.id}_status_badge", text: "Needs Input", wait: 5

    # Exactly once. A backfill that cannot recognise a row it already has would
    # satisfy the assertion above just as well with two copies of it.
    assert_equal 1, timeline_row_count(session),
      "the backfill appended a duplicate of a row already on screen"

    # Live updates are restored too, or the next broadcast is missed as well.
    assert_equal 1, reopen_calls,
      "the controller did not reopen the consumer, so the page came back stale-but-quiet"
  end

  test "a page recovered in place is live again afterwards" do
    session = create_session
    visit session_path(session, filter: "verbose")
    wait_for_turbo_streams_connected

    tune_recovery(stale_after: 0)
    instrument_page

    kill_cable_socket
    reopen_from_bfcache

    assert wait_for_recovery, "the controller never finished recovering"
    wait_for_turbo_streams_connected(timeout: 15)

    session.update!(status: :needs_input)
    assert_selector "#session_#{session.id}_status_badge", text: "Needs Input", wait: 15
  end

  test "a socket found dead on becoming visible is recovered the same way" do
    session = create_session
    visit session_path(session, filter: "verbose")
    wait_for_turbo_streams_connected

    tune_recovery(stale_after: 0)
    instrument_page

    kill_cable_socket
    Log.create!(session: session, level: "info", content: "MISSED WHILE HIDDEN")

    hide_then_show

    assert wait_for_recovery, "the controller never finished recovering"
    assert same_document?, "a stale visibility return reloaded the page"
    assert_empty recorded_events, "a stale visibility return navigated instead of backfilling"
    assert_selector "#session_#{session.id}_timeline", text: "MISSED WHILE HIDDEN", wait: 5
  end

  test "reopening the PWA with a live socket does nothing at all" do
    session = create_session
    visit session_path(session, filter: "verbose")
    wait_for_turbo_streams_connected

    tune_recovery(stale_after: 0)
    instrument_page

    reopen_from_bfcache

    assert wait_for_recovery, "the controller never reported on the reopen"
    assert_equal [ true ], recoveries.map { |r| r["socketWasOpen"] },
      "a live socket was treated as dead"
    assert_empty recorded_events,
      "reopening the PWA navigated even though the cable was still connected"
    assert same_document?

    session.update!(status: :needs_input)
    assert_selector "#session_#{session.id}_status_badge", text: "Needs Input", wait: 5
  end

  test "a brief hide is ignored" do
    session = create_session
    visit session_path(session, filter: "verbose")
    wait_for_turbo_streams_connected

    # The real 5s window. Kill the socket first so this pins the duration gate
    # specifically: with a live socket the later isOpen() check would keep the
    # page still anyway, and the test would pass with the gate deleted.
    tune_recovery(stale_after: 5000)
    instrument_page
    kill_cable_socket

    hide_then_show
    sleep 1.5

    assert_empty recoveries, "a hide shorter than staleAfter recovered anyway"
    assert_empty recorded_events, "a hide shorter than staleAfter reloaded the page"
    assert same_document?
  end

  # The duplication case the id has to prevent. A row that arrived over the
  # socket while the page was in the foreground is rendered by BroadcastService
  # (no transcript_index); the backfill's copy is rendered by the controller
  # (with one). If the id disagreed between those two paths, every row received
  # since page load would be appended a second time on the first reopen.
  test "a row that arrived live is not duplicated by the reopen" do
    session = create_session
    visit session_path(session, filter: "verbose")
    wait_for_turbo_streams_connected

    # Arrives over the live socket, the way an agent's output does.
    Log.create!(session: session, level: "info", content: "ARRIVED OVER THE SOCKET")
    assert_selector "#session_#{session.id}_timeline", text: "ARRIVED OVER THE SOCKET", wait: 5
    assert_equal 1, timeline_row_count(session)

    tune_recovery(stale_after: 0)
    instrument_page
    kill_cable_socket

    Log.create!(session: session, level: "info", content: "MISSED WHILE BACKGROUNDED")

    reopen_from_bfcache
    assert wait_for_recovery, "the controller never finished recovering"

    assert_selector "#session_#{session.id}_timeline", text: "MISSED WHILE BACKGROUNDED", wait: 5
    assert_equal 2, timeline_row_count(session),
      "the reopen duplicated the row that had arrived over the socket"
  end

  # Reopening twice is the normal case — the user switches apps repeatedly — and
  # it is where an id that is unstable *within* the backfill path would show up.
  test "reopening twice does not accumulate copies" do
    session = create_session
    visit session_path(session, filter: "verbose")
    wait_for_turbo_streams_connected

    tune_recovery(stale_after: 0)
    instrument_page

    kill_cable_socket
    Log.create!(session: session, level: "info", content: "MISSED WHILE BACKGROUNDED")

    reopen_from_bfcache
    assert wait_for_recovery, "the first reopen never finished recovering"
    assert_equal 1, timeline_row_count(session)

    # The guard holds for 2s past a recovery, so let it release before the second.
    sleep 2.5
    page.execute_script("window.__zimmerRecovered = []")
    kill_cable_socket

    reopen_from_bfcache
    assert wait_for_recovery, "the second reopen never finished recovering"

    assert_equal 1, timeline_row_count(session),
      "a second reopen appended another copy of the row the first one recovered"
    assert same_document?
    assert_empty recorded_events
  end

  # Elicitation banners are added AND removed by broadcasts, so the region syncs
  # rather than appends: an approval answered while the app was away has to come
  # off the page, not sit there as a dead prompt.
  test "an elicitation resolved while the socket was dead is removed on reopen" do
    session = create_session
    elicitation = Elicitation.create!(
      session: session,
      request_id: "req-#{SecureRandom.hex(8)}",
      mode: "form",
      message: "APPROVE THE THING?",
      requested_schema: { "type" => "object", "properties" => {} },
      meta: {},
      expires_at: 1.hour.from_now
    )

    visit session_path(session, filter: "verbose")
    wait_for_turbo_streams_connected
    assert_selector "#session_#{session.id}_elicitations", text: "APPROVE THE THING?", wait: 5

    tune_recovery(stale_after: 0)
    instrument_page
    kill_cable_socket

    elicitation.update!(status: "accept", response_content: { "ok" => true }, responded_at: Time.current)

    reopen_from_bfcache
    assert wait_for_recovery, "the controller never finished recovering"

    assert_no_selector "#session_#{session.id}_elicitations", text: "APPROVE THE THING?", wait: 5
    assert same_document?, "the elicitation sync reloaded the page"
  end

  # The fallback exists so that a backfill which cannot run leaves a current page
  # rather than a quietly stale one. Losing the reader's place is the price, and
  # it is the right price.
  test "a backfill that cannot fetch falls back to a replacing visit" do
    session = create_session
    visit session_path(session, filter: "verbose")
    wait_for_turbo_streams_connected

    tune_recovery(stale_after: 0)
    instrument_page
    page.execute_script("window.fetch = () => Promise.reject(new Error('offline'))")

    kill_cable_socket
    reopen_from_bfcache

    # The fallback is observed by its effect rather than by `turbo:visit`: with
    # `fetch` broken Turbo's own visit cannot complete either, so it falls all
    # the way through to a browser-level load — which takes the instrumentation
    # with it. The document being replaced is the durable signal.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until same_document? == false
      flunk "a backfill that could not fetch left the page stale instead of falling back" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.1
    end

    # And the page it landed on is a working one, not an error state.
    assert_selector "#session_#{session.id}_timeline", visible: :all, wait: 10
  end
end
