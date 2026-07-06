# frozen_string_literal: true

require "test_helper"
require "rake"

class MaintenanceTasksTest < ActiveSupport::TestCase
  setup do
    # Load rake tasks
    Rails.application.load_tasks if Rake::Task.tasks.empty?

    # Clear any existing sessions (pending flows and notifications first due to foreign key constraints)
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Session.destroy_all
  end

  teardown do
    # Clear tasks for next test
    Rake::Task.clear
    ENV.delete("DRY_RUN")
  end

  test "dry run mode does not modify sessions" do
    # Create session with orphaned PID (use a very high PID that won't exist)
    session = Session.create!(
      prompt: "Test",
      status: "running",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      metadata: { "process_pid" => 999999999 }
    )

    # Run task in dry run mode
    ENV["DRY_RUN"] = "true"
    output = capture_io do
      Rake::Task["maintenance:cleanup:orphaned_processes"].execute
    end.first

    # Session should not be modified
    session.reload
    assert_equal "running", session.status
    assert_equal 999999999, session.metadata["process_pid"]

    # Verify output mentions dry run
    assert_match(/DRY RUN/, output)
    assert_match(/Would update session to 'failed' status/, output)
  end

  test "identifies orphaned PID references" do
    # Create session with orphaned PID (use a very high PID that won't exist)
    session = Session.create!(
      prompt: "Test",
      status: "running",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      metadata: { "process_pid" => 999999998 }
    )

    output = capture_io do
      Rake::Task["maintenance:cleanup:orphaned_processes"].reenable
      Rake::Task["maintenance:cleanup:orphaned_processes"].invoke
    end.first

    # Session should be updated to failed
    session.reload
    assert_equal "failed", session.status
    assert_nil session.metadata["process_pid"]
    assert_equal "orphaned_pid", session.metadata["cleanup_reason"]
    assert session.metadata["cleaned_at"].present?

    # Should have a log entry
    assert session.logs.where(level: "info").any?
    assert_match(/Process 999999998 not found/, session.logs.last.content)

    # Verify output
    assert_match(/Orphaned PID references found: 1/, output)
    assert_match(/Sessions cleaned up: 1/, output)
  end

  test "ignores sessions with running processes" do
    # Create session with our own PID (guaranteed to be running)
    session = Session.create!(
      prompt: "Test",
      status: "running",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      metadata: { "process_pid" => Process.pid }
    )

    output = capture_io do
      Rake::Task["maintenance:cleanup:orphaned_processes"].reenable
      Rake::Task["maintenance:cleanup:orphaned_processes"].invoke
    end.first

    # Session should not be modified
    session.reload
    assert_equal "running", session.status
    assert_equal Process.pid, session.metadata["process_pid"]

    # Verify output shows process is running
    assert_match(/Process #{Process.pid} is running/, output)
    assert_match(/Orphaned PID references found: 0/, output)
  end

  test "handles multiple sessions with mixed states" do
    # Create mix of sessions
    running_session = Session.create!(
      prompt: "Running",
      status: "running",
      metadata: { "process_pid" => Process.pid },
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git"
    )

    orphaned_session1 = Session.create!(
      prompt: "Orphaned 1",
      status: "running",
      metadata: { "process_pid" => 999999997 },
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git"
    )

    orphaned_session2 = Session.create!(
      prompt: "Orphaned 2",
      status: "running",
      metadata: { "process_pid" => 999999996 },
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git"
    )

    no_pid_session = Session.create!(
      prompt: "No PID",
      status: "waiting",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git"
    )

    output = capture_io do
      Rake::Task["maintenance:cleanup:orphaned_processes"].reenable
      Rake::Task["maintenance:cleanup:orphaned_processes"].invoke
    end.first

    # Running session should stay running
    running_session.reload
    assert_equal "running", running_session.status
    assert_equal Process.pid, running_session.metadata["process_pid"]

    # Orphaned sessions should be failed
    orphaned_session1.reload
    assert_equal "failed", orphaned_session1.status
    assert_nil orphaned_session1.metadata["process_pid"]

    orphaned_session2.reload
    assert_equal "failed", orphaned_session2.status
    assert_nil orphaned_session2.metadata["process_pid"]

    # No PID session should be unchanged
    no_pid_session.reload
    assert_equal "waiting", no_pid_session.status

    # Verify output
    assert_match(/Found 3 session\(s\) with process PIDs/, output)
    assert_match(/Orphaned PID references found: 2/, output)
    assert_match(/Sessions cleaned up: 2/, output)
  end

  test "ignores archived sessions" do
    # Create archived session with PID
    archived_session = Session.create!(
      prompt: "Archived",
      status: "archived",
      metadata: { "process_pid" => 999999995 },
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git"
    )

    output = capture_io do
      Rake::Task["maintenance:cleanup:orphaned_processes"].reenable
      Rake::Task["maintenance:cleanup:orphaned_processes"].invoke
    end.first

    # Archived session should not be checked or modified
    archived_session.reload
    assert_equal "archived", archived_session.status
    assert_equal 999999995, archived_session.metadata["process_pid"]

    # Should report 0 sessions with PIDs (archived are excluded)
    assert_match(/Found 0 session\(s\) with process PIDs/, output)
  end

  test "handles sessions without PIDs" do
    # Create sessions without PIDs
    Session.create!(
      prompt: "Waiting",
      status: "waiting",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git"
    )

    Session.create!(
      prompt: "Failed",
      status: "failed",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git"
    )

    output = capture_io do
      Rake::Task["maintenance:cleanup:orphaned_processes"].reenable
      Rake::Task["maintenance:cleanup:orphaned_processes"].invoke
    end.first

    # Should report no sessions with PIDs
    assert_match(/Found 0 session\(s\) with process PIDs/, output)
    assert_match(/No sessions with PIDs found/, output)
  end

  test "logs cleanup actions to session" do
    session = Session.create!(
      prompt: "Test logging",
      status: "running",
      metadata: { "process_pid" => 999999994 },
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git"
    )

    initial_log_count = session.logs.count

    capture_io do
      Rake::Task["maintenance:cleanup:orphaned_processes"].reenable
      Rake::Task["maintenance:cleanup:orphaned_processes"].invoke
    end

    session.reload

    # Should have at least one new log entry
    assert session.logs.count > initial_log_count

    # Check log content
    cleanup_log = session.logs.where(level: "info").last
    assert_not_nil cleanup_log
    assert_match(/Process 999999994 not found/, cleanup_log.content)
    assert_match(/orphaned process cleanup task/, cleanup_log.content)
  end

  test "updates session metadata with cleanup info" do
    session = Session.create!(
      prompt: "Test metadata",
      status: "running",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      metadata: { "process_pid" => 999999993, "some_key" => "some_value" }
    )

    capture_io do
      Rake::Task["maintenance:cleanup:orphaned_processes"].reenable
      Rake::Task["maintenance:cleanup:orphaned_processes"].invoke
    end

    session.reload

    # Check metadata was updated
    assert_equal "orphaned_pid", session.metadata["cleanup_reason"]
    assert session.metadata["cleaned_at"].present?

    # Existing metadata should be preserved
    assert_equal "some_value", session.metadata["some_key"]
  end
end
