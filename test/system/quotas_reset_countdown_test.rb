require "application_system_test_case"

# The /quotas time displays, rendered in a real browser: the "Resets in" line on
# an account card, and the Account Pool's countdown to the moment work is
# unblocked.
#
# The reported bug: a card showed the label "Resets in" with nothing after it.
# `time_until_reset` reported days, hours and minutes, so the last minute before
# a reset had no whole unit left — every component floored to zero and the join
# produced "", which the card interpolated straight after the label.
#
# The second half is the same reading taken later: a snapshot's recorded status
# describes the window that was open when it was taken, and the card kept
# rendering that status after the window's reset time had passed — a red
# "Exceeded" badge sitting beside the 0.0% and the green "Window reset" line the
# same snapshot produced.
#
# The first two are one card away from each other in the shape the bug was
# reported in, so one page render covers them. The third is the pool banner
# above those cards, and needs a pool that is out of capacity rather than a
# single card, so it renders its own page.
class QuotasResetCountdownTest < ApplicationSystemTestCase
  # Alongside the failure screenshots Rails writes, so CI's artifact upload
  # picks them up.
  SCREENSHOT_DIR = Rails.root.join("tmp", "capybara")

  setup do
    # QuotasController#show reconciles the worker's ~/.claude credential files on
    # render. Point those paths at an empty tmp dir so the page render performs no
    # real filesystem work and reconcile is a clean no-op during the test.
    @tmpdir = Dir.mktmpdir
    @orig_claude_json = ClaudeAuthProvider::CLAUDE_JSON_PATH
    @orig_credentials_json = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    stub_claude_path(:CLAUDE_JSON_PATH, File.join(@tmpdir, "claude.json"))
    stub_claude_path(:CREDENTIALS_JSON_PATH, File.join(@tmpdir, ".credentials.json"))
  end

  teardown do
    stub_claude_path(:CLAUDE_JSON_PATH, @orig_claude_json)
    stub_claude_path(:CREDENTIALS_JSON_PATH, @orig_credentials_json)
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  test "a card in the last minute before a reset names the wait instead of rendering a bare label" do
    account = claude_accounts(:exceeded)
    # The shape the bug was reported in: the 5-hour window already reset, the
    # weekly one about to. Comfortably under a minute, with enough slack that a
    # slow page load cannot push it past the reset and change which branch runs.
    account.quota_snapshots.create!(
      subscription_type: "claude_max", rate_limit_tier: "tier_4",
      utilization_5h: 1.0, status_5h: "exceeded", reset_5h: 1.hour.ago,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: 50.seconds.from_now,
      trigger: "page_view"
    )

    visit quotas_url

    card = find("#account_card_#{account.id}")

    assert card.has_text?("Resets in < 1m"),
           "the last minute before a reset should name the wait, got: #{card.text.inspect}"

    # The bug itself, stated as the invariant the label depends on: no "Resets
    # in" anywhere on the page may be followed by nothing. Asserting the text
    # above proves the fixed branch; this proves no other card slipped through.
    blank_labels = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("p"))
        .map((p) => p.textContent.trim())
        .filter((t) => t.replace(/\\s+/g, " ") === "Resets in")
        .length
    JS
    assert_equal 0, blank_labels, "no card should render 'Resets in' with no duration after it"

    # The 5-hour window reset an hour before this reading. The card corrects the
    # counter to 0.0% and says so in green; the recorded "exceeded" status
    # describes a window that no longer exists, so it is not shown beside them.
    # Matched on exact text — the account's own header badge reads "Quota
    # Exceeded", which a substring match would pick up and pass on.
    assert card.has_text?("Window reset"), "the reset 5-hour window should say so"
    card.assert_no_selector("span", exact_text: "Exceeded")

    # The control on that rule: the weekly window is still open, so its status is
    # still a fact about the account and is still shown.
    assert card.has_selector?("span", exact_text: "Rejected"),
           "a status whose window is still open should be badged"

    capture("quotas-reset-countdown", card)
  end

  test "an account whose windows have cleared does not keep presenting as quota exceeded" do
    # The shape it was reported in: the account still carries the sticky
    # quota_exceeded column, and its own latest reading says both windows are
    # Allowed with room to spare. Rendered in a real browser at a phone width,
    # because a card whose badge contradicts the two bars beneath it is a bug you
    # see rather than one you assert.
    account = claude_accounts(:exceeded)
    account.quota_snapshots.create!(
      subscription_type: "claude_max", rate_limit_tier: "tier_4",
      utilization_5h: 0.35, status_5h: "allowed", reset_5h: 26.minutes.from_now,
      utilization_7d: 0.12, status_7d: "allowed", reset_7d: 6.days.from_now,
      trigger: "scheduled"
    )
    at_phone_width do
      visit quotas_url

      card = find("#account_card_#{account.id}")

      assert card.has_selector?("span", exact_text: "Active"),
             "the badge should follow the reading beside it, got: #{card.text.inspect}"
      card.assert_no_selector("span", exact_text: "Quota Exceeded")
      assert card.has_text?("35.0%"), "the 5-hour reading the badge is derived from"
      assert card.has_text?("12.0%"), "the 7-day reading the badge is derived from"

      # And the pool caught up with the page, rather than the page merely papering
      # over a column rotation is still refusing to serve from.
      assert account.reload.active?

      # The card is the widest thing on this page; if it fits a phone, the page does.
      overflow = page.evaluate_script(
        "document.documentElement.scrollWidth - document.documentElement.clientWidth"
      )
      assert_equal 0, overflow, "the page should not scroll horizontally at 375px"

      capture("quotas-cleared-account-badge", card)
    end
  end

  # Part two of the same report: "add a dynamic countdown timer ... ticking down
  # by second". A clock that only ticks in a unit test is a clock nobody
  # watched, so this runs it in a real browser — at a phone width, because that
  # is where Zimmer gets read and where a 30px number is most likely to overrun
  # the screen.
  test "the Account Pool counts down, second by second, to the moment work is unblocked" do
    ClaudeAccountQuotaSnapshot.delete_all
    account = claude_accounts(:primary)
    # The shape Tadas reported: the 5-hour window is already empty, the week is
    # spent, and the week is what the pool is waiting for. Three minutes out, so
    # the clock reads minutes and seconds and each tick is visible.
    deadline = 3.minutes.from_now
    account.quota_snapshots.create!(
      subscription_type: "claude_max", rate_limit_tier: "tier_4",
      utilization_5h: 0.0, status_5h: "allowed", reset_5h: 90.minutes.from_now,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: deadline,
      trigger: "page_view"
    )

    at_phone_width do
      visit quotas_url

      banner = find("[data-controller='unblock-countdown']")
      assert banner.has_text?("Work unblocked in"),
             "the pool should say what the clock is counting down to, got: #{banner.text.inspect}"
      # Driven off the absolute instant, not off a remaining-duration string —
      # a page left open must not freeze on the wait as the server rendered it.
      assert_equal deadline.utc.iso8601,
                   banner["data-unblock-countdown-deadline-value"]

      readings = [ banner.find("[data-unblock-countdown-target='remaining']").text ]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      3.times { readings << next_reading(banner, readings.last) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      seconds = readings.map { |text| clock_seconds(text) }
      assert_equal seconds.sort.reverse, seconds,
                   "the clock should count down, not up or sideways: #{readings.inspect}"
      # A second of wall clock is a second off the clock — the tick is the real
      # rate, not an animation.
      assert_in_delta elapsed, seconds.first - seconds.last, 2,
                      "the clock should track wall time: #{readings.inspect} over #{elapsed.round(1)}s"
      # Nothing has passed yet, so the note about it stays out of the way.
      banner.assert_no_text("That moment has passed")

      # The clock is the widest thing this change adds; if it fits a phone, the
      # banner does.
      overflow = page.evaluate_script(
        "document.documentElement.scrollWidth - document.documentElement.clientWidth"
      )
      assert_equal 0, overflow, "the page should not scroll horizontally at 375px"
      past_edge = page.evaluate_script(<<~JS)
        (function () {
          const limit = document.documentElement.clientWidth;
          return Array.from(document.querySelectorAll("[data-controller='unblock-countdown'] *"))
            .filter((el) => el.getBoundingClientRect().right > limit + 1)
            .map((el) => `${el.tagName.toLowerCase()}.${el.classList.value}`);
        })()
      JS
      assert_equal [], past_edge, "nothing in the countdown may sit past the right edge"

      capture("quotas-unblock-countdown-375", banner)

      # The deadline crossing while the page is open. Handed to the live
      # controller rather than waited out, so the assertion is about what it
      # does at zero — say the moment passed — rather than about how long the
      # test is willing to sit there.
      page.execute_script(<<~JS)
        const el = document.querySelector("[data-controller='unblock-countdown']");
        const controller = window.Stimulus.getControllerForElementAndIdentifier(el, "unblock-countdown");
        controller.deadline = new Date(Date.now() - 1000);
        controller.tick();
      JS

      assert_equal "Work unblocked", banner.find("[data-unblock-countdown-target='label']").text
      assert_equal "now", banner.find("[data-unblock-countdown-target='remaining']").text,
                   "a passed deadline should stop at the moment rather than run negative"
      assert banner.has_text?("That moment has passed"),
             "and should say the reading is stale rather than freezing on 0:00"
      # And it stopped: no interval is left running to count up past zero.
      assert page.evaluate_script(<<~JS), "the expired clock should clear its interval"
        (function () {
          const el = document.querySelector("[data-controller='unblock-countdown']");
          const controller = window.Stimulus.getControllerForElementAndIdentifier(el, "unblock-countdown");
          return controller.interval === null;
        })()
      JS
    end
  end

  private

  # The next reading after `previous`, waited for rather than slept through:
  # Capybara blocks until the element's text actually changes, so a repaint that
  # lands late is a slower sample rather than a duplicate one, and a clock that
  # never ticks fails here with its own message instead of quietly passing a
  # uniqueness check.
  def next_reading(banner, previous)
    banner.assert_no_selector("[data-unblock-countdown-target='remaining']",
      exact_text: previous, wait: 5)
    banner.find("[data-unblock-countdown-target='remaining']").text
  end

  # "1:59" or "2:04:31" or "1d 02:04:31" back to seconds, for asserting the
  # direction and the rate of the tick.
  def clock_seconds(text)
    days, _, rest = text.rpartition("d ")
    parts = rest.split(":").map(&:to_i)
    parts.reduce(0) { |total, part| (total * 60) + part } + (days.to_i * 86_400)
  end

  # Render at a phone viewport and put the window back however the block exits.
  # Workers reuse one browser across tests, so a width left behind here is a
  # width the next test in this worker inherits.
  def at_phone_width
    window = page.driver.browser.manage.window
    original = window.size
    window.resize_to(375, 900)
    yield
  ensure
    window.resize_to(original.width, original.height) if original
  end

  def capture(name, element)
    FileUtils.mkdir_p(SCREENSHOT_DIR)
    scroll_into_center(element)
    page.save_screenshot(SCREENSHOT_DIR.join("proof-#{name}.png"))
  end

  def stub_claude_path(const, value)
    ClaudeAuthProvider.send(:remove_const, const)
    ClaudeAuthProvider.const_set(const, value)
  end
end
