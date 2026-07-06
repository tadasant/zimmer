require "application_system_test_case"

# Tests for session detail page scrolling behavior:
# - Initial page load: Data loads, jumps to bottom immediately
# - Limited initial load: Only 100 messages loaded initially (per INITIAL_TIMELINE_ITEMS_LIMIT)
# - Running sessions: New messages auto-append and auto-scroll to bottom when tailing
# - User scroll up: Disables auto-scroll (no longer tailing)
# - Scroll back to bottom: Re-enables auto-scroll (tailing again)
# - Infinite scroll (upward): When scrolling up to the top, load older messages
class SessionScrollBehaviorTest < ApplicationSystemTestCase
  # Create a session with many messages for infinite scroll testing
  def create_session_with_many_messages(count:)
    transcript_entries = count.times.map do |i|
      role = i.even? ? "user" : "assistant"
      timestamp = (Time.now.utc - (count - i).minutes).iso8601
      {
        type: role,
        message: { role: role, content: "Message #{i + 1} - This is a #{role} message" },
        timestamp: timestamp
      }.to_json
    end.join("\n")

    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test session with #{count} messages",
      status: :running,
      agent_runtime: "claude_code",
      branch: "main",
      transcript: transcript_entries
    )
  end

  # Poll `block` every `interval` seconds until it returns truthy or `timeout`
  # elapses. Returns the block's last value (truthy on success, false on
  # timeout). Mirrors the hand-rolled polling in
  # ApplicationSystemTestCase#wait_for_turbo_streams_connected: deterministic
  # waiting on observable state instead of a fixed `sleep` that races async work.
  def wait_until(timeout: 15, interval: 0.05)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep interval
    end
    false
  end

  # Current number of timeline items in the DOM. Uses wait: 0 so each poll is a
  # single synchronous query rather than incurring Capybara's implicit wait.
  def timeline_item_count
    page.all("[data-timeline-item]", wait: 0).count
  end

  # Whether the infinite-scroll controller still reports older items to load.
  # Returns nil if the controller isn't mounted yet.
  def infinite_scroll_has_more?
    page.evaluate_script(<<~JS)
      (function() {
        const el = document.querySelector('[data-controller~="infinite-scroll"]');
        const controller = el && window.Stimulus.getControllerForElementAndIdentifier(el, 'infinite-scroll');
        return controller ? controller.hasMoreValue : null;
      })();
    JS
  end

  # Trigger loading the next batch of older items, then wait for them to be
  # appended. Returns the resulting item count.
  #
  # We click the "Load earlier messages" button
  # (data-action="click->infinite-scroll#loadMoreClicked") rather than doing
  # `window.scrollTo(0, 0)` and relying on the IntersectionObserver. In headless
  # Chrome a programmatic instant scroll does not reliably deliver an
  # intersection notification, so the observer's loadMore() often never fires and
  # the item count stays put no matter how long we wait — that was the true
  # source of the flakiness (the batch never loads, not merely loads slowly).
  # The button dispatches the exact same loadMoreClicked -> loadMore() path the
  # observer uses, so we still exercise the real fetch / append / scroll-restore
  # / pagination-state code deterministically. This still fails loudly if
  # infinite scroll genuinely stops appending items: the count never grows and
  # the wait times out, failing the caller's assertion.
  def load_older_batch_and_wait(previous_count, timeout: 15)
    page.execute_script(<<~JS)
      (function() {
        const btn = document.querySelector('[data-infinite-scroll-target="loadMoreButton"]');
        if (btn) btn.click();
      })();
    JS
    wait_until(timeout: timeout) { timeline_item_count > previous_count }
    timeline_item_count
  end

  test "session detail page initially scrolls to bottom after loading" do
    # Create a session with enough messages to have scrollable content
    session = create_session_with_many_messages(count: 50)

    visit session_path(session)

    # Wait for timeline content to load
    assert_selector "[data-timeline-item]", minimum: 1

    # Use JavaScript to check if we're at the bottom
    # Give time for scroll to complete
    sleep 0.5

    at_bottom = page.evaluate_script(<<~JS)
      (function() {
        const scrollHeight = document.documentElement.scrollHeight;
        const scrollTop = window.scrollY;
        const windowHeight = window.innerHeight;
        // Consider "at bottom" if within 150px (generous threshold for test stability)
        return (scrollHeight - scrollTop - windowHeight) < 150;
      })();
    JS

    assert at_bottom, "Page should be scrolled to the bottom after loading"
  end

  test "session detail page loads limited items initially with infinite scroll trigger" do
    # Create a session with more than the limit (100)
    session = create_session_with_many_messages(count: 150)

    visit session_path(session)

    # Wait for timeline content to load
    assert_selector "[data-timeline-item]", minimum: 1

    # Wait for initial scroll to bottom and IntersectionObserver to be set up
    # This ensures we check item count BEFORE any infinite scroll auto-triggers
    sleep 0.8

    # Count loaded items - should be ~100 (the INITIAL_TIMELINE_ITEMS_LIMIT)
    loaded_items = page.all("[data-timeline-item]").count

    # Should show approximately 100 items initially, not all 150
    assert loaded_items <= 110, "Should load limited items initially (got #{loaded_items}, expected <= 110)"
    assert loaded_items >= 90, "Should load at least 90 items (got #{loaded_items})"

    # Should show "Load more" indicator when there are more items
    assert_selector "[data-infinite-scroll-target='loadMoreTrigger']"
  end

  test "scrolling up disables auto-scroll tailing" do
    session = create_session_with_many_messages(count: 50)

    visit session_path(session)
    assert_selector "[data-timeline-item]", minimum: 1

    # Wait for initial scroll to bottom
    sleep 0.5

    # Check initial tailing state
    initial_tailing = page.evaluate_script(<<~JS)
      (function() {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(
          document.querySelector('[data-controller~="auto-scroll"]'),
          'auto-scroll'
        );
        return controller ? controller.tailing : null;
      })();
    JS

    assert_equal true, initial_tailing, "Should be tailing initially after scroll to bottom"

    # Scroll up
    page.execute_script("window.scrollTo(0, 0)")
    sleep 0.3

    # Check tailing state after scrolling up
    tailing_after_scroll_up = page.evaluate_script(<<~JS)
      (function() {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(
          document.querySelector('[data-controller~="auto-scroll"]'),
          'auto-scroll'
        );
        return controller ? controller.tailing : null;
      })();
    JS

    assert_equal false, tailing_after_scroll_up, "Should NOT be tailing after scrolling up"
  end

  test "scrolling back to bottom re-enables tailing" do
    session = create_session_with_many_messages(count: 50)

    visit session_path(session)
    assert_selector "[data-timeline-item]", minimum: 1

    # Wait for initial scroll
    sleep 0.5

    # Scroll up first
    page.execute_script("window.scrollTo(0, 0)")
    sleep 0.3

    # Verify tailing is disabled
    tailing_disabled = page.evaluate_script(<<~JS)
      (function() {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(
          document.querySelector('[data-controller~="auto-scroll"]'),
          'auto-scroll'
        );
        return controller ? !controller.tailing : null;
      })();
    JS

    assert tailing_disabled, "Tailing should be disabled after scrolling up"

    # Scroll back to bottom
    page.execute_script("window.scrollTo(0, document.body.scrollHeight)")
    sleep 0.3

    # Check tailing state is re-enabled
    tailing_after_scroll_down = page.evaluate_script(<<~JS)
      (function() {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(
          document.querySelector('[data-controller~="auto-scroll"]'),
          'auto-scroll'
        );
        return controller ? controller.tailing : null;
      })();
    JS

    assert_equal true, tailing_after_scroll_down, "Should be tailing again after scrolling back to bottom"
  end

  test "infinite scroll loads more items when scrolling to top" do
    # Create a session with more than the limit (100)
    session = create_session_with_many_messages(count: 150)

    visit session_path(session)

    # Wait for timeline content to load
    assert_selector "[data-timeline-item]", minimum: 1

    # Wait for initial scroll to bottom and IntersectionObserver to be set up
    sleep 0.8

    # Count initial loaded items
    initial_count = page.all("[data-timeline-item]").count
    assert initial_count <= 110, "Should have limited items initially"

    # Trigger loading older items and wait deterministically for the next batch
    # to append (via the "Load earlier messages" button — see
    # load_older_batch_and_wait for why we don't rely on scroll + the observer).
    final_count = load_older_batch_and_wait(initial_count)

    # Should have loaded more items
    assert final_count > initial_count, "Should have loaded more items after triggering infinite scroll (initial: #{initial_count}, final: #{final_count})"
  end

  test "infinite scroll maintains scroll position when loading older items" do
    # Create a session with more than the limit (100)
    session = create_session_with_many_messages(count: 150)

    visit session_path(session)
    assert_selector "[data-timeline-item]", minimum: 1

    # Wait for initial scroll to bottom and IntersectionObserver to be set up
    # (both use requestAnimationFrame delays)
    sleep 0.8

    # Count initial items to verify we have limited load
    initial_count = page.all("[data-timeline-item]").count
    assert initial_count <= 110, "Should have limited items initially"

    # Capture the scroll position before loading older items. The page is pinned
    # near the bottom after the initial auto-scroll, so scrollY is > 0 here.
    scroll_y_before = page.evaluate_script("window.scrollY")

    # Trigger loading older items and wait deterministically for the next batch
    # to append (via the "Load earlier messages" button — see
    # load_older_batch_and_wait for why we don't rely on scroll + the observer).
    final_count = load_older_batch_and_wait(initial_count)
    assert final_count > initial_count,
      "Infinite scroll should load older items (initial: #{initial_count}, final: #{final_count})"

    # Older items are prepended ABOVE the current content, so to keep the user on
    # the same content the controller restores scroll position (in a
    # requestAnimationFrame) to old_scroll_top + height_of_prepended_content.
    # The net effect is scrollY increasing past its pre-load value — rather than
    # snapping to the top (0). Poll for it since restoration runs asynchronously
    # after the append.
    restored = wait_until { page.evaluate_script("window.scrollY") > scroll_y_before }
    assert restored,
      "Scroll position should be maintained after loading older items " \
      "(expected scrollY > #{scroll_y_before}, got #{page.evaluate_script("window.scrollY")})"
  end

  test "items count display shows filtered count based on log level" do
    # Create a session with both messages and logs
    session = sessions(:with_transcript)

    # Add some logs
    session.logs.create!(content: "Test log message 1", level: "info")
    session.logs.create!(content: "Test log message 2", level: "debug")

    visit session_path(session)

    # The items count should be visible
    assert_selector "[data-infinite-scroll-target='itemsCount']"

    # Verify the count updates when filter changes (this tests the filter-count integration)
    # Note: The actual count will depend on how many items are filtered
    items_count_text = find("[data-infinite-scroll-target='itemsCount']").text
    assert items_count_text.present?, "Items count should be displayed"
  end

  test "running session indicator is visible above follow-up form when session is running" do
    session = sessions(:running)

    visit session_path(session)

    # The running indicator is now part of the follow-up form (compact bar above input)
    assert_selector "[id$='_running_indicator']", visible: :all
    assert_text "Agent is running"
    # The follow-up form should be visible and fixed at bottom
    assert_selector "[id$='_follow_up_form'].fixed.bottom-0", visible: :all
  end

  test "infinite scroll continues loading through multiple pages until all items loaded" do
    # Create a session with 500 messages (5 pages of 100 items each)
    # This tests that infinite scroll works continuously, not just once
    session = create_session_with_many_messages(count: 500)

    visit session_path(session)

    # Wait for timeline content to load
    assert_selector "[data-timeline-item]", minimum: 1

    # Wait for initial scroll to bottom and IntersectionObserver to be set up
    sleep 0.8

    # Count initial loaded items - should be ~100
    initial_count = page.all("[data-timeline-item]").count
    assert initial_count <= 110, "Should have limited items initially (got #{initial_count})"
    assert initial_count >= 90, "Should have at least 90 items (got #{initial_count})"

    # Track loading progress
    previous_count = initial_count
    load_attempts = 0
    max_attempts = 10 # Safety limit to prevent infinite loops

    # Keep loading older items until we have all 500
    while timeline_item_count < 500 && load_attempts < max_attempts
      load_attempts += 1

      # If no more items to load, break
      break unless infinite_scroll_has_more?

      # Trigger the next batch and wait deterministically for it to append.
      current_count = load_older_batch_and_wait(previous_count)

      # Verify we loaded more items than before
      assert current_count > previous_count,
        "Load attempt #{load_attempts}: Should have loaded more items (previous: #{previous_count}, current: #{current_count})"

      previous_count = current_count
    end

    # Verify we loaded all items
    final_count = timeline_item_count
    assert_equal 500, final_count,
      "Should have loaded all 500 items after #{load_attempts} load attempts (got #{final_count})"

    # Verify the "Load more" trigger is now hidden since all items are loaded
    assert_equal false, infinite_scroll_has_more?, "hasMoreValue should be false after loading all items"
  end

  test "can load all 1000 messages with repeated upward scrolling" do
    # Full test with 1000 messages to verify large session handling
    session = create_session_with_many_messages(count: 1000)

    visit session_path(session)

    # Wait for timeline content to load
    assert_selector "[data-timeline-item]", minimum: 1

    # Wait for initial scroll to bottom and IntersectionObserver to be set up
    sleep 0.8

    # Count initial loaded items
    initial_count = page.all("[data-timeline-item]").count
    assert initial_count <= 110, "Should have limited items initially"

    # Load all items by repeatedly triggering the next batch
    max_iterations = 15 # 1000 items / ~100 per load = ~10 loads needed, with buffer
    iteration = 0
    previous_count = initial_count

    loop do
      iteration += 1
      break if iteration > max_iterations

      # Check if there are more items to load
      break unless infinite_scroll_has_more?

      # Trigger the next batch and wait deterministically for it to append.
      previous_count = load_older_batch_and_wait(previous_count)
    end

    # Verify all items are loaded
    final_count = timeline_item_count
    assert_equal 1000, final_count,
      "Should have loaded all 1000 items (got #{final_count} after #{iteration} iterations)"
  end

  # The dashboard drawer renders the same detail partial but scrolls inside its
  # own overflow-y-auto panel rather than on the window. The scroll controllers
  # must target that container so the transcript opens at the bottom — matching
  # the full-page view.
  test "opening a session in the dashboard drawer scrolls to the bottom of the transcript" do
    session = create_session_with_many_messages(count: 50)

    visit root_url

    find("a[aria-label='View session #{session.id}']").click

    # Wait for the drawer to open and the detail to load into the lazy frame.
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='false']"
    within "turbo-frame#session_detail" do
      assert_selector "[data-timeline-item]", minimum: 1
    end

    # Give the double-rAF initial scroll time to run.
    sleep 0.5

    at_bottom = page.evaluate_script(<<~JS)
      (function() {
        const panel = document.querySelector("[data-session-drawer-target='panel']");
        const container = panel.querySelector(".overflow-y-auto");
        // Consider "at bottom" if within 150px (generous threshold for test stability)
        return (container.scrollHeight - container.scrollTop - container.clientHeight) < 150;
      })();
    JS

    assert at_bottom, "Drawer should be scrolled to the bottom of the transcript after opening"
  end

  # The fix that keeps the drawer pinned to the bottom (on open and while
  # live-tailing) hinges on the scroll controllers resolving the drawer's own
  # [data-scroll-container] panel as the scroller. If detection regresses to
  # probing computed overflow, it races layout and silently attaches to the
  # wrong element, so the drawer stops auto-tailing. Assert the auto-scroll
  # controller resolved its scroll target to the drawer panel.
  test "dashboard drawer auto-scroll controller resolves the drawer scroll container" do
    session = create_session_with_many_messages(count: 50)

    visit root_url
    find("a[aria-label='View session #{session.id}']").click

    assert_selector "[data-session-drawer-target='panel'][aria-hidden='false']"
    within "turbo-frame#session_detail" do
      assert_selector "[data-timeline-item]", minimum: 1
    end

    # Let connect()'s triple-rAF resolve the active scroll target.
    sleep 0.5

    targets_container = page.evaluate_script(<<~JS)
      (function() {
        const el = document.querySelector('[data-controller~="auto-scroll"]');
        const controller = window.Stimulus.getControllerForElementAndIdentifier(el, 'auto-scroll');
        if (!controller) return null;
        const container = controller.findScrollContainer();
        return container ? container.hasAttribute('data-scroll-container') : false;
      })();
    JS

    assert_equal true, targets_container,
      "Drawer auto-scroll should resolve the [data-scroll-container] panel as its scroller"
  end

  # Contrast with the drawer: in the full-page view there is no
  # [data-scroll-container] ancestor and the window is the scroller, so the
  # controller must resolve no inner container (returns null). This guards
  # against the detection accidentally latching onto an unrelated overflow
  # element and breaking full-page tailing.
  test "full-page session view auto-scroll controller uses the window scroller" do
    session = create_session_with_many_messages(count: 50)

    visit session_path(session)
    assert_selector "[data-timeline-item]", minimum: 1

    sleep 0.5

    uses_window = page.evaluate_script(<<~JS)
      (function() {
        const el = document.querySelector('[data-controller~="auto-scroll"]');
        const controller = window.Stimulus.getControllerForElementAndIdentifier(el, 'auto-scroll');
        if (!controller) return null;
        return controller.findScrollContainer() === null;
      })();
    JS

    assert_equal true, uses_window,
      "Full-page view should have no inner scroll container (window is the scroller)"
  end

  # Opening the drawer must not move the dashboard underneath it: the body is
  # pinned in place (position: fixed) while the drawer is open and the exact
  # scroll offset is restored on close, so the user never loses their place.
  # This is the "no jiggle" guarantee.
  test "opening and closing the dashboard drawer preserves the dashboard scroll position" do
    # Enough sessions that the dashboard is comfortably taller than the viewport.
    25.times do |i|
      Session.create!(
        git_root: "https://github.com/test/repo.git",
        prompt: "Scroll-lock filler session #{i}",
        status: :needs_input,
        agent_runtime: "claude_code",
        branch: "main"
      )
    end
    target = create_session_with_many_messages(count: 10)

    page.current_window.resize_to(1000, 760)
    visit root_url

    assert_selector "a[aria-label='View session #{target.id}']", visible: :all

    # Scroll the dashboard to a known, non-zero position.
    page.execute_script("window.scrollTo(0, 300)")
    sleep 0.2
    scroll_before = page.evaluate_script("window.scrollY")
    assert scroll_before > 0, "Precondition: dashboard should be scrollable/scrolled (got #{scroll_before})"

    # Open via a synthetic click (element.click(), no Capybara actionability
    # scroll-into-view) so we exercise the app's behavior, not the driver's.
    js_click(find("a[aria-label='View session #{target.id}']", visible: :all))

    assert_selector "[data-session-drawer-target='panel'][aria-hidden='false']"

    # While open, the body is taken out of the scroll flow so nothing underneath
    # can scroll — this is what prevents the jiggle.
    assert_equal "fixed", page.evaluate_script("document.body.style.position"),
      "Body should be pinned (position: fixed) while the drawer is open"

    # Close with Escape; the dashboard must return to exactly where it was.
    find("body").send_keys(:escape)
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='true']", visible: :all

    sleep 0.2
    scroll_after = page.evaluate_script("window.scrollY")
    assert_in_delta scroll_before, scroll_after, 2,
      "Dashboard scroll should be restored on close (before: #{scroll_before}, after: #{scroll_after})"
    assert_equal "", page.evaluate_script("document.body.style.position"),
      "Body position should be unlocked after close"
  end
end
