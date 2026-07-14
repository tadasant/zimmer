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
  if ENV["CI"]
    options.binary = "/usr/bin/chromium-browser"
    # Disable sandbox in CI where we run as root in containers
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

  # Wait until every <turbo-cable-stream-source> on the page has its ActionCable
  # subscription confirmed (signaled by Turbo setting a `connected` attribute on
  # the element after `subscriptionConnected` fires).
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
  # Call this helper after `visit` and before triggering any change you expect
  # to propagate via Turbo Streams. Raises if no `<turbo-cable-stream-source>`
  # exists on the page — that case is intentional: a test that relies on Turbo
  # Stream broadcasts should fail loudly if the source element is missing
  # rather than silently passing because no broadcast was ever needed.
  def wait_for_turbo_streams_connected(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      ready = page.evaluate_script(<<~JS)
        (function() {
          const sources = document.querySelectorAll('turbo-cable-stream-source');
          if (sources.length === 0) return false;
          return Array.from(sources).every(el => el.hasAttribute('connected'));
        })()
      JS
      return if ready
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise Capybara::ExpectationNotMet,
          "Turbo Stream subscriptions did not connect within #{timeout}s"
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
