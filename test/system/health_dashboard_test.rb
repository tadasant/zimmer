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
      branch: "main",
      execution_provider: "local_filesystem"
    )
    Session.create!(
      prompt: "Test 2",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
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
      execution_provider: "local_filesystem",
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
end
