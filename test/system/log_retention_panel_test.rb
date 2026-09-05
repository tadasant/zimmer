# frozen_string_literal: true

require "application_system_test_case"

# The human half of the answer to "is the logs table bounded, and is retention
# running?"
#
# That question had no answer at all on production before tadasant/zimmer#437:
# Postgres is a managed cluster with no shell, a session container has no `psql`,
# and managed-Postgres storage is not scraped into VictoriaMetrics — which is why
# the issue was filed with production's exposure unmeasured. So the panel is not
# decoration; it is the only surface a person can reach.
class LogRetentionPanelTest < ApplicationSystemTestCase
  include MobileOverflowAssertions

  SCREENSHOT_DIR = Rails.root.join("tmp", "capybara")

  # Capybara resets the session between tests but NOT the browser window, so a
  # test that shrinks it to a phone leaves every later test looking at a phone.
  teardown do
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  setup do
    session = Session.create!(
      prompt: "Demo session behind the log retention panel",
      status: :archived,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
    now = Time.current
    rows = 40.times.map do |i|
      at = now - (3.days - (i * 60).seconds)
      { session_id: session.id, content: "[State Machine] transition #{i}", level: "info", created_at: at, updated_at: at }
    end
    Log.insert_all(rows)
    # `reltuples` is -1 until the table has been analyzed, which is what the panel
    # reports as "unknown" rather than as zero.
    ActiveRecord::Base.connection.execute("ANALYZE logs")
  end

  test "the health page says how big the logs table is and what retention is in force" do
    visit health_dashboard_path

    assert_selector "h3", text: "Log Retention"

    within(:xpath, "//h3[normalize-space()='Log Retention']/ancestor::div[contains(@class,'rounded-lg')][1]") do
      # The policy, in the words the model states it in.
      assert_text "rows are kept #{(Log::RETENTION / 1.day).to_i} days"
      assert_text "(#{(Log::VERBOSE_RETENTION / 1.day).to_i} for verbose)"
      assert_text "LogRetentionJob"

      # The four readings that answer "is it bounded, and is it working".
      assert_text "Rows (est.)"
      assert_text "Total size"
      assert_text "Indexes"
      assert_text "Oldest row"

      # A table whose oldest row is inside the window is healthy, and says so in
      # a sentence rather than only in a badge colour.
      assert_text(/Oldest log row is \d+ days? old/)
    end

    FileUtils.mkdir_p(SCREENSHOT_DIR)
    page.execute_script(<<~JS)
      const heading = [...document.querySelectorAll("h3")].find(h => h.textContent.includes("Log Retention"));
      if (heading) heading.scrollIntoView({ block: "start" });
    JS
    page.save_screenshot(SCREENSHOT_DIR.join("proof-log-retention-panel.png"))
  end

  test "the panel fits a phone viewport" do
    page.driver.browser.manage.window.resize_to(MOBILE_WIDTH, MOBILE_HEIGHT)

    visit health_dashboard_path
    assert_selector "h3", text: "Log Retention"

    assert_no_horizontal_overflow("health dashboard (log retention panel)")

    FileUtils.mkdir_p(SCREENSHOT_DIR)
    page.execute_script(<<~JS)
      const heading = [...document.querySelectorAll("h3")].find(h => h.textContent.includes("Log Retention"));
      if (heading) heading.scrollIntoView({ block: "start" });
    JS
    page.save_screenshot(SCREENSHOT_DIR.join("proof-log-retention-panel-375.png"))
  end
end
