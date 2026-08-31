# frozen_string_literal: true

require "application_system_test_case"

# The human half of invariant 11: "which one-time tasks have run, which are
# pending, and which failed" has to be answerable from a browser, because the
# shell that would otherwise answer it does not exist on this deployment.
#
# Also the only place a screenshot for the PR can come from — an agent session
# has no local Postgres to drive the app against, so the proof is a `proof-*.png`
# the `test-system` job uploads as an artifact.
class PostDeployTasksPanelTest < ApplicationSystemTestCase
  SCREENSHOT_DIR = Rails.root.join("tmp", "capybara")

  # Capybara resets the session between tests but NOT the browser window, so a
  # test that shrinks it to a phone leaves every test that runs after it looking
  # at a phone — where anything `hidden md:block` is present in the DOM and not
  # visible. Restoring it is the idiom mobile_horizontal_overflow_test.rb uses,
  # for the same reason.
  teardown do
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  setup do
    PostDeployTaskRun.create!(
      version: "20260830100500", name: "FixClonePathMetadata", status: "succeeded",
      attempts: 2, started_at: 3.hours.ago, finished_at: 2.hours.ago, last_ran_at: 2.hours.ago,
      stats: { "repaired" => 41, "skipped" => 0 }
    )
    PostDeployTaskRun.create!(
      version: "20260901090000", name: "PruneOrphanedWidgets", status: "pending",
      last_ran_at: 4.minutes.ago, stats: { "deleted" => 18_400 },
      cursor: { "sweep_last_id" => 918_233 }, attempts: 7, started_at: 20.minutes.ago
    )
    PostDeployTaskRun.create!(
      version: "20260901093000", name: "RekeyTranscriptCache", status: "failed",
      attempts: 6, failures: PostDeployTaskRun::RETRY_DELAYS.size + 1,
      started_at: 2.hours.ago, last_ran_at: 25.minutes.ago, last_error_at: 25.minutes.ago,
      last_error: "Errno::ENOENT: No such file or directory @ rb_sysopen - /var/cache/transcripts/index"
    )
  end

  test "the health page shows what ran, what is pending and what is stuck" do
    visit health_dashboard_path

    assert_selector "h3", text: "Post-Deploy Tasks"

    # Every state a reader has to be able to tell apart, and the error text they
    # need in order to act on the stuck one.
    assert_text "FixClonePathMetadata"
    assert_text "PruneOrphanedWidgets"
    assert_text "RekeyTranscriptCache"
    assert_text "blocked"
    assert_text "No such file or directory"
    assert_text "repaired=41"

    # The way out, without a shell: re-arm and run.
    assert_button "Re-arm and run now"

    FileUtils.mkdir_p(SCREENSHOT_DIR)
    page.execute_script(<<~JS)
      const heading = [...document.querySelectorAll("h3")].find(h => h.textContent.includes("Post-Deploy Tasks"));
      if (heading) heading.scrollIntoView({ block: "start" });
    JS
    page.save_screenshot(SCREENSHOT_DIR.join("proof-post-deploy-tasks-panel.png"))
  end

  test "the panel fits a phone viewport" do
    page.driver.browser.manage.window.resize_to(375, 812)

    visit health_dashboard_path
    assert_selector "h3", text: "Post-Deploy Tasks"

    overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")

    assert_operator overflow, :<=, 1, "the health page overflows a 375px viewport by #{overflow}px"

    FileUtils.mkdir_p(SCREENSHOT_DIR)
    page.execute_script(<<~JS)
      const heading = [...document.querySelectorAll("h3")].find(h => h.textContent.includes("Post-Deploy Tasks"));
      if (heading) heading.scrollIntoView({ block: "start" });
    JS
    page.save_screenshot(SCREENSHOT_DIR.join("proof-post-deploy-tasks-panel-375.png"))
  end
end
