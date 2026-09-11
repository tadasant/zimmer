# frozen_string_literal: true

require "application_system_test_case"

class HealthDashboardTest < ApplicationSystemTestCase
  test "visiting the health dashboard" do
    visit health_dashboard_path

    assert_selector "h1", text: "System Health Dashboard"
    assert_selector "h3", text: "Process Health"
    assert_selector "h3", text: "Session Health"
    assert_selector "h3", text: "System Health"
    assert_selector "h3", text: "Maintenance Actions"
  end

  test "health dashboard shows overall status" do
    visit health_dashboard_path

    # Should show overall status message
    assert_text(/All systems operational|issues detected|warnings detected/)
  end

  test "health dashboard shows session statistics" do
    # Create some sessions
    Session.create!(
      prompt: "Test 1",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
    Session.create!(
      prompt: "Test 2",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit health_dashboard_path

    assert_text "Total Sessions"
    assert_text "Failure Rate"
  end

  test "can navigate back to sessions" do
    visit health_dashboard_path

    click_link "Back to Sessions"

    assert_current_path root_path
  end

  test "health dashboard has refresh button" do
    visit health_dashboard_path

    assert_selector "button", text: "Refresh"
  end

  test "health dashboard has export link" do
    visit health_dashboard_path

    assert_selector "a", text: "Export"
  end

  test "health dashboard shows cleanup actions" do
    visit health_dashboard_path

    assert_text "Trash Sessions Older Than 7 Days"
    assert_text "Open Job Queue Dashboard"
    assert_text "Open Supervisor Dashboard"
  end

  test "health dashboard accessible from sessions index" do
    visit root_path

    click_link "Health"

    assert_current_path health_dashboard_path
    assert_selector "h1", text: "System Health Dashboard"
  end

  test "archive old sessions button is present" do
    visit health_dashboard_path

    # Just verify the button text exists (button_to generates a button element)
    assert_text "Trash Sessions Older Than 7 Days"
  end

  test "health dashboard shows queue statistics" do
    visit health_dashboard_path

    assert_text "Queue Depth"
    assert_text "Jobs/Hour"
    assert_text "Ready"
    assert_text "Scheduled"
    assert_text "Processing"
    assert_text "Failed"
  end

  test "health dashboard shows worker statistics" do
    visit health_dashboard_path

    assert_text "Workers"
    assert_text(/active \//) # Should show "X active / Y total"
  end

  test "health dashboard shows database status" do
    visit health_dashboard_path

    assert_text "Database"
    assert_text(/Connected|Disconnected/)
  end

  test "recent failures table shows failed sessions" do
    # Create a failed session
    session = Session.create!(
      prompt: "Failed task",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: "My Failed Test Session"
    )
    session.logs.create!(content: "Something went wrong", level: "error")

    visit health_dashboard_path

    assert_text "Recent Failures"
    assert_text "My Failed Test Session"
  end

  test "status badges show correct colors" do
    visit health_dashboard_path

    # With no issues, should show healthy badges
    assert_selector ".bg-green-100", minimum: 1
  end

  # The backlog breakdown is a stack of variable-length lines — "inference 51,
  # agents 40, default 33, …" and a job-class list that is longer still. That is
  # exactly the shape that sets its own container's width and lands off the right
  # edge of a phone, where /health is read when the backlog page fires at night.
  # Pinned at 375px against BOTH probes: the document must be no wider than the
  # screen, and nothing inside the panel may stick out past it — the second is not
  # redundant, because a clipping ancestor hides an overflow from the first.
  test "the backlog breakdown fits a 375px viewport" do
    now = Time.current
    blank = { queue_name: nil, job_class: nil, scheduled_at: nil, locked_by_id: nil,
              locked_at: nil, performed_at: nil, created_at: now, updated_at: now }
    rows = { "inference" => [ "SessionStatusSummaryJob", 51, 39 ],
             "agents" => [ "AgentSessionJob", 40, 40 ],
             "default" => [ "SessionTitleJob", 33, 38 ],
             "pollers" => [ "SlackTriggerPollerJob", 15, 37 ],
             "maintenance" => [ "DeferredCloneCleanupJob", 9, 36 ] }.flat_map do |lane, (klass, count, mins)|
      Array.new(count) { blank.merge(queue_name: lane, job_class: klass, scheduled_at: mins.minutes.ago) }
    end
    rows += Array.new(2) do
      blank.merge(queue_name: "inference", job_class: "SessionStatusSummaryJob",
                  locked_by_id: SecureRandom.uuid, locked_at: 41.minutes.ago, performed_at: 41.minutes.ago)
    end
    GoodJob::Job.insert_all(rows)

    page.driver.browser.manage.window.resize_to(375, 812)

    begin
      visit health_dashboard_path
      assert_text "Backlog Breakdown"
      assert_text "SessionStatusSummaryJob 51"

      assert page.evaluate_script(
        "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1"
      ), "the health dashboard must not be wider than a 375px viewport"

      panel_overflow = page.evaluate_script(<<~JS)
        (function () {
          const limit = document.documentElement.clientWidth;
          const heading = Array.from(document.querySelectorAll("h4"))
            .find((h) => h.textContent.trim() === "Backlog Breakdown");
          if (!heading) return [ "the panel did not render" ];
          return Array.from(heading.parentElement.querySelectorAll("*"))
            .filter((el) => el.getBoundingClientRect().right > limit + 1)
            .slice(0, 10)
            .map((el) => el.tagName.toLowerCase() + "." + el.classList.value);
        })()
      JS
      assert_empty panel_overflow,
        "the backlog breakdown sticks out past a 375px viewport: #{panel_overflow.inspect}"
    ensure
      page.driver.browser.manage.window.resize_to(1400, 900)
    end
  end

  # The Cron Freshness card carries a per-key table, which cannot shrink below its
  # min-content width and so lives in an `overflow-x-auto` wrapper. The reading that
  # answers "has this sweep been running" added a column to it, so the assertion is
  # that the widening stayed INSIDE that scroller: the document is no wider than the
  # phone, and nothing in the card sticks out past the screen except through a
  # wrapper the reader can scroll.
  test "the cron freshness card fits a 375px viewport" do
    GoodJob::CronEntry.stubs(:all).returns([
      GoodJob::CronEntry.new(key: :zombie_reaper, cron: "*/5 * * * *", class: "ZombieReaperJob")
    ])
    GoodJob::Process.insert_all([
      { id: SecureRandom.uuid, state: { cron_enabled: true }, created_at: 2.days.ago, updated_at: Time.current }
    ])
    last_tick = Time.current.beginning_of_minute - (Time.current.min % 5).minutes
    GoodJob::Job.insert_all((0..359).reject { |i| (48..119).cover?(i) }.map do |i|
      at = last_tick - (i * 5).minutes
      { queue_name: "default", job_class: "ZombieReaperJob", cron_key: "zombie_reaper", cron_at: at,
        created_at: at, updated_at: at, scheduled_at: at, finished_at: at + 1 }
    end)

    page.driver.browser.manage.window.resize_to(375, 812)

    begin
      visit health_dashboard_path
      assert_text "Cron Freshness"
      assert_text(/is enqueuing now, but was silent/)

      find("summary", text: /Every key/).click
      assert_selector "th", text: "Last 24 hours"

      assert page.evaluate_script(
        "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1"
      ), "the health dashboard must not be wider than a 375px viewport"

      outside_the_scroller = page.evaluate_script(<<~JS)
        (function () {
          const limit = document.documentElement.clientWidth;
          const heading = Array.from(document.querySelectorAll("h3"))
            .find((h) => h.textContent.trim() === "Cron Freshness");
          if (!heading) return [ "the card did not render" ];
          const card = heading.closest("div.bg-white");
          const scroller = card.querySelector("table").parentElement;
          return Array.from(card.querySelectorAll("*"))
            .filter((el) => el.getBoundingClientRect().right > limit + 1)
            .filter((el) => !scroller.contains(el))
            .slice(0, 10)
            .map((el) => el.tagName.toLowerCase() + "." + el.classList.value);
        })()
      JS
      assert_empty outside_the_scroller,
        "the cron freshness card sticks out past a 375px viewport: #{outside_the_scroller.inspect}"

      assert page.evaluate_script(<<~JS), "the per-key table must stay inside a scrollable wrapper"
        (function () {
          const heading = Array.from(document.querySelectorAll("h3"))
            .find((h) => h.textContent.trim() === "Cron Freshness");
          const scroller = heading.closest("div.bg-white").querySelector("table").parentElement;
          return getComputedStyle(scroller).overflowX === "auto";
        })()
      JS
    ensure
      page.driver.browser.manage.window.resize_to(1400, 900)
    end
  end
end
