require "test_helper"
require "capybara/rails"
require "selenium-webdriver"

# Browser Session Pooling Configuration
# ======================================
# These settings optimize system test performance by:
# 1. Reusing the Rack server thread across test sessions (reuse_server)
# 2. Using a persistent user data directory per parallel worker for faster browser startup
# 3. Disabling unnecessary Chrome features to reduce overhead

# Explicitly enable server reuse (default is true, but being explicit for clarity)
# This ensures the same Rack server thread is reused across all tests in a worker
Capybara.reuse_server = true

# Serve every page with CSS transitions and animations forced to zero duration
# (Capybara injects `transition: none !important; animation-duration: 0s` into each
# HTML response via a Rack middleware).
#
# An element that animates into place is a moving target, and Selenium clicks by
# coordinate: it reads the element's bounding rect, then asks Chrome to dispatch a
# pointer event there, as separate round trips. A mid-transition element has drifted
# by the time the event is dispatched, so the click silently lands on whatever slid
# into those coordinates — the interactability check passed when it ran, so nothing
# raises. That is what made the session-drawer close test flaky.
#
# This covers CSS transitions and animations, which is where the suite's moving
# targets come from. It does NOT defeat a JS-driven `scrollIntoView({ behavior:
# "smooth" })` — per CSSOM-View an explicit `behavior` beats the CSS property — so a
# test driving one of the dropdown controllers that scroll their options that way is
# still clicking at a moving target.
#
# The full diagnosis is in docs/src/content/docs/operate/testing.md.
Capybara.disable_animation = true

# Chrome reports a node detached by a page swap as a generic `UnknownError`, not
# as the `StaleElementReferenceError` Capybara's retry loop knows to swallow — so
# a query that races a re-render errors the test instead of being retried. The
# full diagnosis is in test/support/detached_node_error_translation.rb and in
# docs/src/content/docs/operate/testing.md.
require_relative "support/detached_node_error_translation"
DetachedNodeErrorTranslation.install!

# turbo-rails' own post-`visit` readiness check waits on a cached element handle
# for 2 seconds; this app replaces stream sources to recover them and allows 3
# seconds before doing so. #connect_turbo_cable_stream_sources below overrides it
# with a poll that re-reads the document. Full diagnosis in the support file.
require_relative "support/turbo_stream_connection_wait"

# Generate a unique user data directory for each parallel test worker
# This allows Chrome to reuse profile data between tests, significantly
# reducing browser startup time while maintaining isolation between workers.
#
# Rails sets TEST_ENV_NUMBER for parallel workers: "" for first worker, "2" for second, etc.
# We normalize empty string to "0" for consistent directory naming.
#
# Note: These directories persist between test runs for performance.
# To clean up: rm -rf tmp/chrome_user_data
def chrome_user_data_dir
  @chrome_user_data_dir ||= begin
    worker_id = ENV["TEST_ENV_NUMBER"].to_s.empty? ? "0" : ENV["TEST_ENV_NUMBER"]
    dir = Rails.root.join("tmp", "chrome_user_data", "worker_#{worker_id}")
    FileUtils.mkdir_p(dir)
    dir.to_s
  end
end

def build_selenium_options
  options = Selenium::WebDriver::Chrome::Options.new

  # Use a persistent user data directory for faster browser startup
  # Each parallel worker gets its own directory to avoid conflicts
  options.add_argument("--user-data-dir=#{chrome_user_data_dir}")

  # Disable features that slow down browser startup
  options.add_argument("--disable-search-engine-choice-screen")
  options.add_argument("--disable-dev-shm-usage")
  options.add_argument("--disable-extensions")
  options.add_argument("--disable-default-apps")
  options.add_argument("--disable-background-networking")
  options.add_argument("--disable-sync")
  options.add_argument("--disable-translate")

  # Additional stability flags for CI environments with multiple containers
  # These help prevent ERR_NETWORK_CHANGED errors when Docker networks change
  options.add_argument("--dns-prefetch-disable")
  options.add_argument("--no-first-run")
  options.add_argument("--disable-features=NetworkService,NetworkServiceInProcess")
  options.add_argument("--disable-backgrounding-occluded-windows")
  options.add_argument("--disable-renderer-backgrounding")

  # Allow running tests in headed mode with HEADLESS=false
  unless ENV["HEADLESS"] == "false"
    options.add_argument("--headless=new")
    options.add_argument("--disable-gpu")
  end

  # CI-specific configuration
  options.binary = "/usr/bin/chromium-browser" if ENV["CI"]

  # Chrome's setuid sandbox cannot start in a container that does not grant it
  # the namespaces it wants; Chrome aborts on launch and Selenium reports only
  # "Chrome instance exited". CI has always needed this. An agent dev container
  # needs it for the same reason and has no CI variable set, so it opts in
  # explicitly rather than by pretending to be CI — which would also point the
  # binary at a chromium-browser path that only exists in the CI image.
  if ENV["CI"] || ENV["CHROME_NO_SANDBOX"] == "true"
    options.add_argument("--no-sandbox")
  end

  options
end

Capybara.register_driver :selenium_chrome_headless do |app|
  options = build_selenium_options
  # Explicitly clear storage between tests to prevent test pollution
  # even with persistent user data directories
  Capybara::Selenium::Driver.new(
    app,
    browser: :chrome,
    options: options,
    clear_local_storage: true,
    clear_session_storage: true
  )
end

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium_chrome_headless

  # Assign unique Capybara server ports per parallel worker to prevent EADDRINUSE errors.
  # Capybara's default port auto-assignment has a race condition: it uses TCPServer.new(host, 0)
  # to find a free port, then closes the socket before Puma binds. Between discovery and binding,
  # another worker can claim the same port. Static port assignment eliminates this race.
  # The worker parameter is a zero-indexed integer (0, 1, 2, ...) provided by Rails parallelize.
  parallelize_setup do |worker|
    # Base port 9800 avoids conflicts with ChromeDriver (9515), common services, and ephemeral range
    Capybara.server_port = 9800 + worker
  end

  # Scroll element into center of viewport to avoid fixed headers intercepting clicks
  # Uses JavaScript scrollIntoView with 'center' block option
  def scroll_into_center(element)
    page.execute_script("arguments[0].scrollIntoView({block: 'center', inline: 'center'})", element.native)
    sleep 0.2 # Brief pause to let scroll complete
  end

  # Click element using JavaScript to bypass interception issues
  def js_click(element)
    page.execute_script("arguments[0].click()", element.native)
  end

  # Wait until every <turbo-cable-stream-source> element present in the page has
  # its ActionCable subscription confirmed (signaled by Turbo setting a `connected`
  # attribute on the element after `subscriptionConnected` fires).
  #
  # Capybara's `visit` returns as soon as the HTML response is parsed, but the
  # WebSocket subscription handshake happens asynchronously after the JS runs.
  # Any Turbo Stream broadcast fired before the handshake completes is dropped —
  # ActionCable does not queue messages for late subscribers. Tests that call
  # `session.update!` (or an AASM event) immediately after `visit` are racing
  # the handshake; on a slow CI run the broadcast lands before any subscriber
  # exists and the assertion that waits for the broadcast-rendered element
  # times out.
  #
  # Call this helper after any navigation that does NOT go through `visit` (the
  # dashboard drawer, a `click_link`) and before triggering a change you expect to
  # propagate via Turbo Streams. `visit` already runs the same wait — see
  # #connect_turbo_cable_stream_sources below.
  #
  # Raises if no `<turbo-cable-stream-source>` ever appears — that case is
  # intentional: a test that relies on Turbo Stream broadcasts should fail loudly
  # if the source element is missing rather than silently passing because no
  # broadcast was ever needed.
  def wait_for_turbo_streams_connected(timeout: TurboStreamConnectionWait::TIMEOUT)
    TurboStreamConnectionWait.wait(timeout:, require_source: true) do
      page.evaluate_script(TurboStreamConnectionWait::READING_SCRIPT)
    end
  end

  # turbo-rails runs this after every `visit` in the suite — its engine defines
  # `def visit(...) = super.tap { connect_turbo_cable_stream_sources }` on
  # ActionDispatch::SystemTestCase, driven by `config.turbo
  # .test_connect_after_actions`, which defaults to `%i[visit]`.
  #
  # Its own implementation resolves the unconnected sources once and then waits on
  # each *cached element handle* to gain `[connected]`, for at most
  # `Capybara.default_max_wait_time` (2s). That is both too short for this app —
  # `cable_reconnect_controller.js` allows a source 3s before it even attempts a
  # re-subscribe — and pinned to an element the page is entitled to replace, which
  # is exactly what that controller's `replaceWith` re-subscribe does. Either way
  # the wait raises `Capybara::ExpectationNotMet: Item does not match the provided
  # selector` from inside `visit`, before the test body runs.
  #
  # Overriding the method rather than the `visit` wrapper keeps the fix wherever
  # turbo-rails chooses to call it, including any action added to
  # `test_connect_after_actions` later. The full diagnosis is in
  # test/support/turbo_stream_connection_wait.rb and in
  # docs/src/content/docs/operate/testing.md.
  #
  # Unlike #wait_for_turbo_streams_connected this does not require a source to
  # exist: most pages in the suite broadcast nothing, and a page with no sources
  # has nothing to wait for.
  def connect_turbo_cable_stream_sources
    TurboStreamConnectionWait.wait(require_source: false) do
      page.evaluate_script(TurboStreamConnectionWait::READING_SCRIPT)
    end
  end

  # The session detail screen's Transcript panel is a collapsed <details> (see
  # app/views/sessions/_detail.html.erb), so its contents are in the DOM but not
  # *visible* — and Capybara asserts on visible text. Almost every system test
  # that opens a session then asserts on something inside the transcript.
  #
  # So `visit` opens it, rather than ~90 call sites each remembering to. This
  # cannot mask a regression in the collapsed-by-default behaviour itself: that
  # is asserted directly, on the rendered HTML, in
  # test/controllers/sessions_controller_status_panel_test.rb.
  #
  # Navigation that does NOT go through `visit` — clicking a card to open the
  # dashboard drawer — has to call #open_transcript_panel itself.
  def visit(*args, **kwargs)
    super
    open_transcript_panel
  end

  # Open every Transcript panel on the page, firing the same `toggle` event a
  # real click does so the transcript-panel controller still scrolls to the
  # newest message. A no-op on pages that have no such panel.
  #
  # `wait` defaults to 0 because the panel is server-rendered and `visit` has
  # already returned by the time this runs. Pass a real wait when the panel
  # arrives asynchronously — the dashboard drawer loads the detail into a lazy
  # turbo-frame, so it is not in the DOM the instant the drawer opens.
  def open_transcript_panel(wait: 0)
    return unless page.has_css?("details[data-controller~='transcript-panel']", wait: wait)

    page.execute_script(<<~JS)
      document.querySelectorAll("details[data-controller~='transcript-panel']").forEach((d) => {
        if (!d.open) {
          d.open = true
          d.dispatchEvent(new Event("toggle"))
        }
      })
    JS
  end

  # Capybara's matchers retry until the page agrees; a plain `assert` on a record
  # reads the database exactly once. A test that asserts a DOM change and then
  # reads a row is reading two independent channels, and the DOM one can be the
  # faster: a broadcast fires from the `after_commit` of one write while the
  # request thread is still doing the work that produces the second. The read
  # then loses a race it never had to enter.
  #
  # So this is the database-side counterpart to the two wait helpers above —
  # poll the block until it is truthy, and fail when the deadline passes. Use it
  # instead of weakening the assertion or sleeping a fixed amount before it.
  #
  # It is deliberately less forgiving than Capybara's own retry loop, which
  # swallows a known set of element errors while it waits: an exception raised
  # inside the block propagates on its first occurrence rather than being
  # retried for the whole timeout. A query that raises is a real failure, and
  # burying it for five seconds would only make it harder to read.
  #
  # It lives here rather than in AssertionHelpers because the race it answers is
  # a system test's own: a second thread serving the page while the test reads
  # behind it.
  def assert_eventually(message = nil, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    satisfied = false

    loop do
      satisfied = yield
      break if satisfied || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end

    # The caller's message says what was expected; the timeout says how long the
    # read waited for it, which is what tells the next reader this was a poll
    # rather than a single-shot assertion.
    assert satisfied, [ message, "not true within #{timeout}s" ].compact.join(" — ")
  end

  # Block until Stimulus has connected the named controller.
  #
  # A controller that fills a field on connect leaves the field server-rendered
  # empty until it runs, and `assert_equal` on a field's value does not retry the
  # way Capybara's matchers do — so a bare read after `visit` measures the pre-JS
  # DOM and can agree with the expected answer by accident.
  def wait_for_stimulus_controller(identifier, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      connected = page.evaluate_script(<<~JS, identifier)
        (function (identifier) {
          const el = document.querySelector(`[data-controller~="${identifier}"]`)
          if (!el || !window.Stimulus) return false
          return Boolean(window.Stimulus.getControllerForElementAndIdentifier(el, identifier))
        })(arguments[0])
      JS
      return if connected
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise Capybara::ExpectationNotMet,
          "the #{identifier} Stimulus controller did not connect within #{timeout}s"
      end
      sleep 0.05
    end
  end

  # Select an agent root via the agent-root-select Stimulus controller.
  #
  # The radios on the new session form are hidden — they exist only to
  # preserve change-event listeners on dependent controllers (goal,
  # mcp-server-select, skills-select, etc.). Capybara's `choose` cannot
  # interact with hidden inputs, so we drive the same code path the
  # autocomplete dropdown uses in production.
  def select_agent_root(name)
    page.execute_script(<<~JS)
      (() => {
        const el = document.querySelector('[data-controller~="agent-root-select"]');
        const ctrl = window.Stimulus.getControllerForElementAndIdentifier(el, 'agent-root-select');
        ctrl.selectRoot(#{name.to_json});
      })();
    JS
    sleep 0.1
  end
end
