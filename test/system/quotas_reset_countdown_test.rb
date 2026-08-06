require "application_system_test_case"

# The "Resets in" line on a /quotas account card, rendered in a real browser.
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
# Both are one card away from each other in the shape the bug was reported in,
# so one page render covers them.
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

  private

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
