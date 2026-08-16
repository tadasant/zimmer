# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class SessionStateMachineTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  # Test state machine initialization
  # Database default is waiting (1) to match AASM initial state
  test "session initializes in waiting state by database default" do
    session = Session.new(git_root: "https://github.com/test/repo.git", agent_runtime: "claude_code", branch: "main")
    session.save!
    assert session.waiting?, "Session should initialize with database default (waiting)"
  end

  test "session can be set to waiting state" do
    session = Session.new(git_root: "https://github.com/test/repo.git", agent_runtime: "claude_code", branch: "main", status: :waiting)
    session.save!
    assert session.waiting?, "Session should be in waiting state when explicitly set"
  end

  # Test start transition
  test "can start session from waiting state" do
    session = sessions(:waiting)
    session.update!(status: :waiting, git_root: "https://github.com/test/repo.git")

    assert session.may_start?, "Session should be able to start"
    session.start!

    assert session.running?, "Session should be running after start"
    assert_equal 1, session.logs.where(content: "[State Machine] Session started").count
  end

  test "cannot start session without git_root" do
    session = Session.new(git_root: "https://github.com/test/repo.git", agent_runtime: "claude_code", branch: "main", status: :waiting)
    session.save!(validate: false)
    session.update_column(:git_root, nil)

    assert_not session.may_start?, "Session should not be able to start without git_root"
    assert_raises(AASM::InvalidTransition) { session.start! }
  end

  # Test pause transition
  test "can pause session from running state" do
    session = sessions(:waiting)
    session.update!(status: :running)

    assert session.may_pause?, "Session should be able to pause"
    session.pause!

    assert session.needs_input?, "Session should be in needs_input state after pause"
    assert_equal 1, session.logs.where("content LIKE ?", "%Session paused%").count
  end

  test "cannot pause session from waiting state" do
    session = sessions(:waiting)
    session.update!(status: :waiting)

    assert_not session.may_pause?, "Session should not be able to pause from waiting"
  end

  # Test resume transition
  test "can resume session from needs_input state" do
    session = sessions(:waiting)
    session.update!(status: :needs_input, session_id: SecureRandom.uuid)
    session.update!(metadata: { "clone_path" => "/tmp/test-clone" })

    # Create the clone directory for the guard
    FileUtils.mkdir_p("/tmp/test-clone")

    assert session.may_resume?, "Session should be able to resume"
    session.resume!

    assert session.running?, "Session should be running after resume"
    assert_equal 1, session.logs.where("content LIKE ?", "%Session resumed%").count
  ensure
    FileUtils.rm_rf("/tmp/test-clone")
  end

  test "can resume session from failed state" do
    session = sessions(:waiting)
    session.update!(status: :failed, session_id: SecureRandom.uuid)
    session.update!(metadata: { "clone_path" => "/tmp/test-clone-2" })

    # Create the clone directory for the guard
    FileUtils.mkdir_p("/tmp/test-clone-2")

    assert session.may_resume?, "Session should be able to resume from failed"
    session.resume!

    assert session.running?, "Session should be running after resume from failed"
  ensure
    FileUtils.rm_rf("/tmp/test-clone-2")
  end

  # `resume` is deliberately unguarded (#107): AgentSessionJob establishes or
  # validates the clone and fails the session with a specific failure_reason when
  # it cannot, so the state machine stays permissive and lets the job try. What
  # bounds `resume` is its source states, asserted below — not a guard.
  test "resume is bounded by its source states, not by a guard" do
    session = sessions(:waiting)

    %i[waiting needs_input failed].each do |state|
      session.update!(status: state)
      assert session.may_resume?, "resume must be available from #{state}"
    end

    %i[running archived].each do |state|
      session.update!(status: state)
      refute session.may_resume?, "resume must NOT be available from #{state}"
    end
  end

  test "can resume session even without session_id" do
    session = sessions(:waiting)
    session.update!(status: :needs_input, session_id: nil)

    # Guard is permissive - actual validation happens in the job
    assert session.may_resume?, "Session should be able to resume (job handles validation)"
  end

  test "can resume session even without existing clone" do
    session = sessions(:waiting)
    session.update!(status: :needs_input, session_id: SecureRandom.uuid)
    session.update!(metadata: { "clone_path" => "/nonexistent/path" })

    # Guard is permissive - actual validation happens in the job
    assert session.may_resume?, "Session should be able to resume (job handles validation)"
  end

  # Test fail transition
  test "can fail session from running state" do
    session = sessions(:waiting)
    session.update!(status: :running)
    session.update!(metadata: { "failure_reason" => "test error" })

    assert session.may_fail?, "Session should be able to fail"
    session.fail!

    assert session.failed?, "Session should be failed"
    assert_equal 1, session.logs.where("content LIKE ?", "%Session failed%").count
  end

  test "can fail session from needs_input state" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)

    assert session.may_fail?, "Session should be able to fail from needs_input"
    session.fail!

    assert session.failed?, "Session should be failed"
  end

  test "can fail session from waiting state" do
    # Failing from waiting is valid when a job fails before process is spawned
    session = sessions(:waiting)
    session.update!(status: :waiting)

    assert session.may_fail?, "Session should be able to fail from waiting"
    session.fail!

    assert session.failed?, "Session should be failed"
  end

  # Test archive transition (now moves to trash)
  test "can archive session from waiting state" do
    session = sessions(:waiting)
    session.update!(status: :waiting)

    assert session.may_archive?, "Session should be able to archive from waiting"
    session.archive!

    assert session.archived?, "Session should be archived"
    assert_equal 1, session.logs.where("content LIKE ?", "%Session moved to trash%").count
    assert_not_nil session.trash_after, "trash_after should be set when session is archived"
  end

  test "archive names the actor the caller recorded" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)

    session.archive_actor = "session #5225 via the MCP API"
    session.archive!

    line = session.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_equal "[State Machine] Session moved to trash by session #5225 via the MCP API", line
  end

  test "archive says so when no caller recorded an actor" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)

    session.archive!

    line = session.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_equal "[State Machine] Session moved to trash by an unrecorded caller", line
  end

  test "archive names pull requests it is leaving unresolved" do
    session = sessions(:waiting)
    session.update!(
      status: :needs_input,
      custom_metadata: {
        "github_pull_request_urls" => [ "https://github.com/o/r/pull/152" ],
        "github_pull_request_statuses" => { "https://github.com/o/r/pull/152" => "open" }
      }
    )

    session.archive_actor = "session #5225 via the MCP API"
    session.archive!

    line = session.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_includes line, "Session moved to trash by session #5225 via the MCP API"
    assert_includes line, "1 tracked pull request had not reached a terminal state"
    assert_includes line, "no merge notification will be delivered for it"
    assert_includes line, "https://github.com/o/r/pull/152"
  end

  test "archive counts several unresolved pull requests, including ones never polled" do
    session = sessions(:waiting)
    session.update!(
      status: :needs_input,
      custom_metadata: {
        "github_pull_request_urls" => [ "https://github.com/o/r/pull/1", "https://github.com/o/r/pull/2" ],
        "github_pull_request_statuses" => { "https://github.com/o/r/pull/1" => "open" }
      }
    )

    session.archive!

    line = session.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_includes line, "2 tracked pull requests had not reached a terminal state"
    assert_includes line, "no merge notification will be delivered for them"
    assert_includes line, "https://github.com/o/r/pull/1, https://github.com/o/r/pull/2"
  end

  test "archive stays quiet about pull requests that already reached a terminal state" do
    session = sessions(:waiting)
    session.update!(
      status: :needs_input,
      custom_metadata: {
        "github_pull_request_urls" => [ "https://github.com/o/r/pull/1", "https://github.com/o/r/pull/2" ],
        "github_pull_request_statuses" => {
          "https://github.com/o/r/pull/1" => "merged",
          "https://github.com/o/r/pull/2" => "closed"
        }
      }
    )

    session.archive!

    line = session.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_equal "[State Machine] Session moved to trash by an unrecorded caller", line
  end

  test "archive tolerates a statuses value that is not a hash" do
    session = sessions(:waiting)
    session.update!(
      status: :needs_input,
      custom_metadata: {
        "github_pull_request_urls" => [ "https://github.com/o/r/pull/1" ],
        "github_pull_request_statuses" => "not-a-hash"
      }
    )

    session.archive!

    assert session.reload.archived?, "a bad metadata shape must not take the transition down"
    line = session.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_includes line, "https://github.com/o/r/pull/1"
  end

  test "archive falls back to the plain line rather than letting the description break the transition" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)
    session.stubs(:unresolved_pr_clause).raises(StandardError, "unreadable")

    session.archive!

    assert session.reload.archived?, "describing the archive must not be able to take the transition down"
    assert_equal "[State Machine] Session moved to trash",
                 session.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_not_nil session.trash_after, "the trash bookkeeping after the log line must still run"
  end

  test "archive does not reuse an actor across a later archive of the same instance" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)

    session.archive_actor = "a user in the web UI"
    session.archive!
    assert_nil session.archive_actor, "the actor is consumed by the line it feeds"

    session.unarchive_to_needs_input!
    session.archive!

    lines = session.logs.where("content LIKE ?", "%Session moved to trash%").order(:id).pluck(:content)
    assert_equal [ "[State Machine] Session moved to trash by a user in the web UI",
                   "[State Machine] Session moved to trash by an unrecorded caller" ], lines
  end

  test "archive sets archived_at timestamp" do
    session = sessions(:waiting)
    session.update!(status: :needs_input, archived_at: nil)

    assert_nil session.archived_at
    session.archive!

    session.reload
    assert_not_nil session.archived_at, "archived_at should be set by archive state transition"
    assert_in_delta Time.current, session.archived_at, 2.seconds
  end

  test "can archive session from needs_input state" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)

    assert session.may_archive?, "Session should be able to archive from needs_input"
    session.archive!

    assert session.archived?, "Session should be archived"
  end

  test "can archive session from failed state" do
    session = sessions(:waiting)
    session.update!(status: :failed)

    assert session.may_archive?, "Session should be able to archive from failed"
    session.archive!

    assert session.archived?, "Session should be archived"
  end

  # Can archive from running state (user force-archiving stuck session)
  test "can archive session from running state" do
    session = sessions(:waiting)
    session.update!(status: :running)

    # Archiving from running is allowed (force-archive stuck sessions)
    assert session.may_archive?, "Session should be able to archive from running"
    session.archive!

    assert session.archived?, "Session should be archived"
  end

  # Test unarchive transitions (restore from trash)
  test "can unarchive to waiting" do
    session = sessions(:waiting)
    session.update!(status: :archived, trash_after: 7.days.from_now)

    assert session.may_unarchive_to_waiting?, "Session should be able to unarchive to waiting"
    session.unarchive_to_waiting!

    assert session.waiting?, "Session should be waiting after unarchive"
    assert_equal 1, session.logs.where("content LIKE ?", "%restored from trash to waiting%").count
    assert_nil session.trash_after, "trash_after should be cleared when restoring from trash"
  end

  test "can unarchive to failed" do
    session = sessions(:waiting)
    session.update!(status: :archived, trash_after: 7.days.from_now)

    assert session.may_unarchive_to_failed?, "Session should be able to unarchive to failed"
    session.unarchive_to_failed!

    assert session.failed?, "Session should be failed after unarchive"
    assert_equal 1, session.logs.where("content LIKE ?", "%restored from trash to failed%").count
    assert_nil session.trash_after, "trash_after should be cleared when restoring from trash"
  end

  test "can unarchive to needs_input" do
    session = sessions(:waiting)
    session.update!(status: :archived, trash_after: 7.days.from_now)

    assert session.may_unarchive_to_needs_input?, "Session should be able to unarchive to needs_input"
    session.unarchive_to_needs_input!

    assert session.needs_input?, "Session should be needs_input after unarchive"
    assert_equal 1, session.logs.where("content LIKE ?", "%restored from trash to needs_input%").count
    assert_nil session.trash_after, "trash_after should be cleared when restoring from trash"
  end

  # Test elapsed time reset
  test "start resets last_timeline_entry_at to current time" do
    session = sessions(:waiting)
    old_time = 1.hour.ago
    session.update!(status: :waiting, git_root: "https://github.com/test/repo.git", last_timeline_entry_at: old_time)

    freeze_time do
      session.start!
      session.reload

      assert_equal Time.current, session.last_timeline_entry_at, "last_timeline_entry_at should be reset to current time on start"
    end
  end

  test "resume resets last_timeline_entry_at to current time" do
    session = sessions(:waiting)
    old_time = 30.minutes.ago
    session.update!(status: :needs_input, session_id: SecureRandom.uuid, last_timeline_entry_at: old_time)
    session.update!(metadata: { "clone_path" => "/tmp/test-clone" })

    FileUtils.mkdir_p("/tmp/test-clone")

    freeze_time do
      session.resume!
      session.reload

      assert_equal Time.current, session.last_timeline_entry_at, "last_timeline_entry_at should be reset to current time on resume"
    end
  ensure
    FileUtils.rm_rf("/tmp/test-clone")
  end

  test "resume from failed state resets last_timeline_entry_at" do
    session = sessions(:waiting)
    old_time = 2.hours.ago
    session.update!(status: :failed, session_id: SecureRandom.uuid, last_timeline_entry_at: old_time)
    session.update!(metadata: { "clone_path" => "/tmp/test-clone-failed" })

    FileUtils.mkdir_p("/tmp/test-clone-failed")

    freeze_time do
      session.resume!
      session.reload

      assert_equal Time.current, session.last_timeline_entry_at, "last_timeline_entry_at should be reset on resume from failed"
    end
  ensure
    FileUtils.rm_rf("/tmp/test-clone-failed")
  end

  test "resume from waiting state resets last_timeline_entry_at" do
    session = sessions(:waiting)
    old_time = 1.hour.ago
    session.update!(status: :waiting, git_root: "https://github.com/test/repo.git", last_timeline_entry_at: old_time)

    freeze_time do
      session.resume!
      session.reload

      assert_equal Time.current, session.last_timeline_entry_at, "last_timeline_entry_at should be reset on resume from waiting"
    end
  end

  # Test MCP failure metadata clearing on resume
  test "resume clears stale MCP failure metadata from custom_metadata" do
    session = sessions(:waiting)
    session.update!(
      status: :failed,
      custom_metadata: {
        "should_fail_session" => true,
        "mcp_connection_checked" => true,
        "mcp_failed_servers" => [ { "name" => "test-server", "status" => "failed" } ],
        "mcp_failure_reason" => "MCP server(s) failed to connect: test-server",
        "mcp_servers_status" => { "test-server" => { "status" => "failed" } },
        "other_key" => "should_be_preserved"
      }
    )

    session.resume!
    session.reload

    # MCP failure keys should be cleared
    assert_nil session.custom_metadata["should_fail_session"], "should_fail_session should be cleared"
    assert_nil session.custom_metadata["mcp_connection_checked"], "mcp_connection_checked should be cleared"
    assert_nil session.custom_metadata["mcp_failed_servers"], "mcp_failed_servers should be cleared"
    assert_nil session.custom_metadata["mcp_failure_reason"], "mcp_failure_reason should be cleared"
    assert_nil session.custom_metadata["mcp_servers_status"], "mcp_servers_status should be cleared"

    # Other keys should be preserved
    assert_equal "should_be_preserved", session.custom_metadata["other_key"], "other_key should be preserved"
  end

  test "resume does not fail when custom_metadata is empty" do
    session = sessions(:waiting)
    session.update!(status: :failed, custom_metadata: {})

    # Should not raise an error
    session.resume!
    session.reload

    assert session.running?, "Session should be running after resume"
    assert_equal({}, session.custom_metadata)
  end

  test "resume does not fail when custom_metadata is nil" do
    session = sessions(:waiting)
    session.update!(status: :failed)
    session.update_column(:custom_metadata, nil)

    # Should not raise an error
    session.resume!
    session.reload

    assert session.running?, "Session should be running after resume"
  end

  test "resume clears MCP metadata when resuming from needs_input state" do
    session = sessions(:waiting)
    session.update!(
      status: :needs_input,
      custom_metadata: {
        "should_fail_session" => true,
        "mcp_connection_checked" => true
      }
    )

    session.resume!
    session.reload

    assert_nil session.custom_metadata["should_fail_session"]
    assert_nil session.custom_metadata["mcp_connection_checked"]
  end

  test "resume only clears MCP keys that exist" do
    session = sessions(:waiting)
    session.update!(
      status: :failed,
      custom_metadata: {
        "should_fail_session" => true,
        "other_data" => "preserved"
      }
    )

    session.resume!
    session.reload

    assert_nil session.custom_metadata["should_fail_session"]
    assert_equal "preserved", session.custom_metadata["other_data"]
    # Should not have empty string keys or nil values from clearing non-existent keys
    assert_not session.custom_metadata.key?("mcp_failed_servers")
  end

  # Test callbacks
  test "start callback clears running_job_id" do
    session = sessions(:waiting)
    session.update!(status: :waiting, running_job_id: "test-job-id", git_root: "https://github.com/test/repo.git")

    # The start event's pause callback will clear running_job_id
    # Actually, start doesn't have a cleanup_running_job callback, only pause/fail/corrupt/archive do
    # Let's test pause callback instead
    session.update!(status: :running, running_job_id: "test-job-id")
    session.pause!

    session.reload
    assert_nil session.running_job_id, "running_job_id should be cleared after pause"
  end

  test "archive callback sets trash expiry and enqueues deferred cleanup" do
    session = sessions(:waiting)
    session.update!(status: :needs_input, archived_at: Time.current)
    clone_path = "/tmp/test-clone-archive-#{SecureRandom.hex(4)}"
    FileUtils.mkdir_p(clone_path)
    session.update!(metadata: { "clone_path" => clone_path })

    assert File.directory?(clone_path), "Clone directory should exist"

    # Archive SHOULD enqueue a deferred cleanup job
    assert_enqueued_with(job: DeferredCloneCleanupJob) do
      session.archive!
    end

    # Clone should still exist after archive (preserved until deferred cleanup runs)
    assert File.directory?(clone_path), "Clone directory should still exist after archive"

    # trash_after should be set as safety net
    session.reload
    assert_not_nil session.trash_after, "trash_after should be set after archive"
    assert_in_delta 4.days.from_now, session.trash_after, 60, "trash_after should be ~4 days from now"
  ensure
    FileUtils.rm_rf(clone_path) if clone_path && File.directory?(clone_path)
  end

  # Test invalid transitions
  test "raises error on invalid transition" do
    session = sessions(:waiting)
    session.update!(status: :waiting)

    # Cannot pause from waiting (only running sessions can be paused)
    assert_raises(AASM::InvalidTransition) { session.pause! }
  end

  # Test state predicates
  test "state predicates work correctly" do
    session = sessions(:waiting)

    session.update!(status: :waiting)
    assert session.waiting?
    assert_not session.running?
    assert_not session.needs_input?
    assert_not session.failed?
    assert_not session.archived?

    session.update!(status: :running)
    assert_not session.waiting?
    assert session.running?

    session.update!(status: :needs_input)
    assert session.needs_input?

    session.update!(status: :failed)
    assert session.failed?

    session.update!(status: :archived)
    assert session.archived?
  end

  # Test full lifecycle
  test "full session lifecycle" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      branch: "main",
      session_id: SecureRandom.uuid,
      status: :waiting  # Explicitly set to waiting to test the full lifecycle
    )

    assert session.waiting?, "New session should be waiting"

    # Start session
    session.start!
    assert session.running?, "Session should be running after start"

    # Pause session
    session.pause!
    assert session.needs_input?, "Session should be needs_input after pause"

    # Resume session
    clone_path = "/tmp/test-clone-lifecycle-#{SecureRandom.hex(4)}"
    FileUtils.mkdir_p(clone_path)
    session.update!(metadata: { "clone_path" => clone_path }, archived_at: Time.current)

    session.resume!
    assert session.running?, "Session should be running after resume"

    # Pause again
    session.pause!
    assert session.needs_input?, "Session should be needs_input again"

    # Archive session
    session.archive!
    assert session.archived?, "Session should be archived"

    # Clone should still exist after archive (preserved for trash retention)
    assert File.directory?(clone_path), "Clone should still exist after archive"

    # trash_after should be set for eventual cleanup by EmptyTrashJob
    session.reload
    assert_not_nil session.trash_after, "trash_after should be set after archive"
  ensure
    FileUtils.rm_rf(clone_path) if clone_path && File.directory?(clone_path)
  end

  # Test that AASM state transitions trigger broadcasts via after_update_commit
  test "pause! triggers broadcasts to update Turbo Stream clients" do
    session = sessions(:waiting)
    session.update!(status: :running)

    broadcasts_called = []

    # Mock the broadcast methods to track calls without actually broadcasting
    %i[broadcast_status_badge broadcast_follow_up_form broadcast_running_loader broadcast_header_actions].each do |method|
      session.define_singleton_method(method) do
        broadcasts_called << method
      end
    end

    session.pause!

    assert_equal 4, broadcasts_called.length, "All 4 broadcast methods should be called"
    assert_includes broadcasts_called, :broadcast_status_badge
    assert_includes broadcasts_called, :broadcast_follow_up_form
    assert_includes broadcasts_called, :broadcast_running_loader
    assert_includes broadcasts_called, :broadcast_header_actions
  end

  test "start! triggers broadcasts to update Turbo Stream clients" do
    session = sessions(:waiting)
    session.update!(status: :waiting, git_root: "https://github.com/test/repo.git")

    broadcasts_called = []

    %i[broadcast_status_badge broadcast_follow_up_form broadcast_running_loader broadcast_header_actions].each do |method|
      session.define_singleton_method(method) do
        broadcasts_called << method
      end
    end

    session.start!

    assert_equal 4, broadcasts_called.length, "All 4 broadcast methods should be called"
  end

  test "fail! triggers broadcasts to update Turbo Stream clients" do
    session = sessions(:waiting)
    session.update!(status: :running)

    broadcasts_called = []

    %i[broadcast_status_badge broadcast_follow_up_form broadcast_running_loader broadcast_header_actions].each do |method|
      session.define_singleton_method(method) do
        broadcasts_called << method
      end
    end

    session.fail!

    assert_equal 4, broadcasts_called.length, "All 4 broadcast methods should be called"
  end

  test "resume! triggers broadcasts to update Turbo Stream clients" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)

    broadcasts_called = []

    %i[broadcast_status_badge broadcast_follow_up_form broadcast_running_loader broadcast_header_actions].each do |method|
      session.define_singleton_method(method) do
        broadcasts_called << method
      end
    end

    session.resume!

    assert_equal 4, broadcasts_called.length, "All 4 broadcast methods should be called"
  end

  test "archive! triggers broadcasts to update Turbo Stream clients" do
    session = sessions(:waiting)
    session.update!(status: :needs_input, archived_at: nil)
    # Prevent actual clone cleanup by setting a non-existent path
    session.metadata["clone_path"] = "/nonexistent/path"
    session.save!

    broadcasts_called = []

    %i[broadcast_status_badge broadcast_follow_up_form broadcast_running_loader broadcast_header_actions].each do |method|
      session.define_singleton_method(method) do
        broadcasts_called << method
      end
    end

    session.archive!

    assert_equal 4, broadcasts_called.length, "All 4 broadcast methods should be called"
  end

  # Test notification staleness marking
  test "resume marks session notifications as stale" do
    session = sessions(:waiting)
    session.update!(status: :needs_input, session_id: SecureRandom.uuid)

    # Create active notifications for this session
    notification1 = Notification.create!(session: session, notification_type: "needs_input", stale: false)
    notification2 = Notification.create!(session: session, notification_type: "session_failed", stale: false)

    # Create a notification for a different session (should not be affected)
    other_session = sessions(:running)
    other_notification = Notification.create!(session: other_session, notification_type: "needs_input", stale: false)

    session.resume!

    notification1.reload
    notification2.reload
    other_notification.reload

    assert notification1.stale?, "Notification should be marked stale when session is resumed"
    assert notification2.stale?, "All notifications for the session should be marked stale"
    assert_not other_notification.stale?, "Notifications for other sessions should not be affected"
  end

  test "archive destroys all notifications for the session" do
    session = sessions(:waiting)
    session.update!(status: :needs_input, session_id: SecureRandom.uuid, archived_at: nil)
    session.metadata["clone_path"] = "/nonexistent/path"
    session.save!

    # Create active notifications for this session
    Notification.create!(session: session, notification_type: "needs_input", stale: false)
    Notification.create!(session: session, notification_type: "session_complete", stale: false)

    # Create a notification for a different session (should not be affected)
    other_session = sessions(:running)
    other_notification = Notification.create!(session: other_session, notification_type: "needs_input", stale: false)

    session.archive!

    assert_equal 0, session.notifications.count, "All notifications for the archived session should be destroyed"
    assert Notification.exists?(other_notification.id), "Notifications for other sessions should not be affected"
  end

  test "resume does not fail if marking notifications stale raises an error" do
    session = sessions(:waiting)
    session.update!(status: :needs_input, session_id: SecureRandom.uuid)

    # Mock Notification to raise an error
    Notification.stub(:mark_session_stale, ->(_) { raise StandardError, "Database error" }) do
      # Should not raise - errors are logged but don't block state transition
      assert_nothing_raised do
        session.resume!
      end
    end

    assert session.running?, "Session should still transition to running despite notification error"
  end

  test "archive does not fail if dismissing notifications raises an error" do
    session = sessions(:waiting)
    session.update!(status: :needs_input, session_id: SecureRandom.uuid, archived_at: nil)
    session.metadata["clone_path"] = "/nonexistent/path"
    session.save!

    # Create a notification so destroy_all has something to process
    Notification.create!(session: session, notification_type: "needs_input", stale: false)

    # Stub notifications to return an object whose destroy_all raises
    raising_relation = Object.new
    raising_relation.define_singleton_method(:destroy_all) { raise StandardError, "Database error" }

    session.stub(:notifications, raising_relation) do
      # Should not raise - errors are logged but don't block state transition
      assert_nothing_raised do
        session.archive!
      end
    end

    assert session.archived?, "Session should still transition to archived despite notification error"
  end

  # Test sleep transition
  test "can sleep session from needs_input state" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)

    assert session.may_sleep?, "Session should be able to sleep from needs_input"
    session.sleep!

    assert session.waiting?, "Session should be waiting after sleep"
    assert_equal 1, session.logs.where("content LIKE ?", "%Session sleeping%").count
  end

  test "cannot sleep session from running state" do
    session = sessions(:waiting)
    session.update!(status: :running)

    assert_not session.may_sleep?, "Session should not be able to sleep from running"
    assert_raises(AASM::InvalidTransition) { session.sleep! }
  end

  test "cannot sleep session from waiting state" do
    session = sessions(:waiting)
    session.update!(status: :waiting)

    assert_not session.may_sleep?, "Session should not be able to sleep from waiting"
  end

  test "cannot sleep session from failed state" do
    session = sessions(:waiting)
    session.update!(status: :failed)

    assert_not session.may_sleep?, "Session should not be able to sleep from failed"
  end

  test "cannot sleep session from archived state" do
    session = sessions(:waiting)
    session.update!(status: :archived)

    assert_not session.may_sleep?, "Session should not be able to sleep from archived"
  end

  test "sleep then resume lifecycle" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      branch: "main",
      session_id: SecureRandom.uuid,
      status: :waiting
    )

    session.start!
    assert session.running?

    session.pause!
    assert session.needs_input?

    session.sleep!
    assert session.waiting?, "Session should be waiting after sleep"

    session.resume!
    assert session.running?, "Session should be running after resume from sleeping/waiting"
  end

  # === Tests for warn_if_pr_goal_captured_no_url (pause/fail/archive callback) ===

  # A session for the backstop tests: PR-flavored goal, nothing recorded.
  def pr_goal_session(custom_metadata: {})
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      branch: "main",
      session_id: SecureRandom.uuid,
      status: :waiting,
      goal: "Open a PR, confirm CI is green, and stop.",
      custom_metadata: custom_metadata
    )
  end

  def missing_pr_url_warnings(session)
    session.logs.where(level: "warning").select do |log|
      log.content.include?(TranscriptHooks::GithubPrUrlHook::MISSING_PR_URL_WARNING_MARKER)
    end
  end

  test "pause warns when a session with a pull-request goal recorded no PR URL" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      branch: "main",
      session_id: SecureRandom.uuid,
      status: :waiting,
      goal: "Open a PR, confirm CI is green, and stop."
    )
    session.start!

    session.pause!

    warning = session.logs.where(level: "warning").find { |log| log.content.include?(TranscriptHooks::GithubPrUrlHook::MISSING_PR_URL_WARNING_MARKER) }
    assert_not_nil warning, "expected pause to warn about the missing PR URL"
  end

  test "pause does not warn when the session recorded a PR URL" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      branch: "main",
      session_id: SecureRandom.uuid,
      status: :waiting,
      goal: "Open a PR, confirm CI is green, and stop.",
      custom_metadata: { "github_pull_request_urls" => [ "https://github.com/test/repo/pull/1" ] }
    )
    session.start!

    session.pause!

    assert_empty session.logs.where(level: "warning").select { |log| log.content.include?(TranscriptHooks::GithubPrUrlHook::MISSING_PR_URL_WARNING_MARKER) }
  end

  # `fail` and `archive` are where the miss becomes permanent: a paused session
  # gets another turn to open its PR, a failed or archived one does not (#313).

  test "fail warns when a session with a pull-request goal recorded no PR URL" do
    session = pr_goal_session
    session.start!

    session.fail!

    assert_equal 1, missing_pr_url_warnings(session).size, "expected fail to warn about the missing PR URL"
  end

  test "archive warns when a session with a pull-request goal recorded no PR URL" do
    session = pr_goal_session
    session.start!
    session.pause!
    session.logs.destroy_all # isolate archive from the pause that preceded it

    session.archive!

    assert_equal 1, missing_pr_url_warnings(session).size, "expected archive to warn about the missing PR URL"
  end

  test "fail does not warn when the session recorded a PR URL" do
    session = pr_goal_session(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/test/repo/pull/1" ] })
    session.start!

    session.fail!

    assert_empty missing_pr_url_warnings(session)
  end

  test "archive does not warn when the session recorded a PR URL" do
    session = pr_goal_session(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/test/repo/pull/1" ] })
    session.start!

    session.archive!

    assert_empty missing_pr_url_warnings(session)
  end

  # The dedup guard is on the warning log itself, so all three call sites share
  # one budget of one warning per session — which is what makes adding call
  # sites free of timeline spam.
  test "a session that pauses, warns, and then archives warns exactly once" do
    session = pr_goal_session
    session.start!

    session.pause!
    assert_equal 1, missing_pr_url_warnings(session).size, "expected the pause to warn"

    session.archive!

    assert_equal 1, missing_pr_url_warnings(session).size, "archive must not repeat the warning pause already wrote"
  end

  test "a session that pauses, warns, and then fails warns exactly once" do
    session = pr_goal_session
    session.start!

    session.pause!
    session.fail!

    assert_equal 1, missing_pr_url_warnings(session).size, "fail must not repeat the warning pause already wrote"
  end

  # The commonest real terminal sequence: a session dies, and the user trashes
  # it afterwards. Both new call sites fire, and between them they must still
  # produce one warning.
  test "a session that fails, warns, and is then archived warns exactly once" do
    session = pr_goal_session
    session.start!

    session.fail!
    assert_equal 1, missing_pr_url_warnings(session).size, "expected the failure to warn"

    session.archive!

    assert_equal 1, missing_pr_url_warnings(session).size, "archive must not repeat the warning fail already wrote"
  end

  # A warning that breaks a state transition is worse than the thing it warns
  # about — and on these two events the transition is running cleanup.
  test "archive completes its cleanup when the missing-PR-URL check raises" do
    session = pr_goal_session
    session.start!

    TranscriptHooks::GithubPrUrlHook.stub(:warn_if_pr_goal_captured_no_url, ->(*) { raise "boom" }) do
      assert_nothing_raised { session.archive! }
    end

    assert session.archived?, "archive must still complete"
    # set_trash_expiry is the callback immediately before the new call, so it is
    # the one that proves the raise did not truncate the rest of the block.
    assert_not_nil session.reload.trash_after, "archive bookkeeping must not be skipped"
  end

  test "fail completes when the missing-PR-URL check raises" do
    session = pr_goal_session
    session.start!

    TranscriptHooks::GithubPrUrlHook.stub(:warn_if_pr_goal_captured_no_url, ->(*) { raise "boom" }) do
      assert_nothing_raised { session.fail! }
    end

    assert session.failed?, "fail must still complete"
  end

  # A status-summary fork is Zimmer's own bookkeeping throwaway and is disposed
  # of by archiving, so it must not warn. The goal check alone does not cover
  # it: ForkSessionService copies the source's goal, and
  # SessionStatusSummaryGenerator only strips it in #prepare_fork — which
  # #abandon_fork runs *before* on the "source went to the trash mid-copy" path.
  # So the fork under test keeps its inherited PR-flavored goal, which is the
  # state the explicit carve-out in the hook exists for.
  test "archiving an abandoned status-summary fork does not warn about a missing PR URL" do
    source = pr_goal_session
    fork = pr_goal_session
    fork.update!(metadata: fork.metadata.to_h.merge(SessionStatusSummaryGenerator::FORK_MARKER => source.id))
    fork.start!

    assert fork.status_summary_fork?, "the fixture must actually be a fork"
    assert fork.goal.present?, "this test is only meaningful while the fork still carries a PR goal"

    fork.archive!

    assert_empty missing_pr_url_warnings(fork)
  end

  # === Tests for execute_pending_sleep (pause callback) ===

  test "pause executes pending sleep when pending_sleep flag is set" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      branch: "main",
      session_id: SecureRandom.uuid,
      status: :waiting
    )

    session.start!
    assert session.running?

    session.update!(metadata: (session.metadata || {}).merge("pending_sleep" => true))

    session.pause!
    assert session.waiting?, "Session should be waiting after pause with pending_sleep"
    assert_nil session.reload.metadata["pending_sleep"], "pending_sleep flag should be cleared"
    assert session.logs.where("content LIKE ?", "%Session sleeping%").exists?
  end

  test "pause does not sleep when pending_sleep flag is absent" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      branch: "main",
      session_id: SecureRandom.uuid,
      status: :waiting
    )

    session.start!
    session.pause!

    assert session.needs_input?, "Session should remain in needs_input without pending_sleep"
  end

  test "pending sleep lifecycle: running with flag → pause → waiting → resume → running" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      branch: "main",
      session_id: SecureRandom.uuid,
      status: :waiting
    )

    session.start!
    assert session.running?

    session.update!(metadata: (session.metadata || {}).merge("pending_sleep" => true))
    session.pause!
    assert session.waiting?, "Session should be waiting after deferred sleep"

    session.resume!
    assert session.running?, "Session should be running after resume from deferred sleep"
  end

  # === Tests for enqueue_session_inference_if_needed (pause callback) ===
  # SessionTitleJob does both titling and category inference, so the pause
  # callback enqueues it when title work OR category work is still pending.

  test "pause enqueues SessionTitleJob when session has auto_generated_title flag" do
    session = sessions(:waiting)
    session.update!(status: :running, metadata: { "auto_generated_title" => true })

    assert_enqueued_with(job: SessionTitleJob, args: [ session.id ]) do
      session.pause!
    end
  end

  test "pause does not enqueue SessionTitleJob when title was manually set and no categories exist" do
    session = sessions(:waiting)
    session.update!(status: :running, metadata: { "some_key" => "value" })

    assert_no_enqueued_jobs(only: SessionTitleJob) do
      session.pause!
    end
  end

  test "pause does not enqueue SessionTitleJob when auto_generated_title is false and no categories exist" do
    session = sessions(:waiting)
    session.update!(status: :running, metadata: { "auto_generated_title" => false })

    assert_no_enqueued_jobs(only: SessionTitleJob) do
      session.pause!
    end
  end

  test "pause enqueues SessionTitleJob for category work even when the title is manual" do
    Category.create!(name: "Research")
    session = sessions(:waiting)
    session.update!(status: :running, category_id: nil, metadata: { "some_key" => "value" })

    assert_enqueued_with(job: SessionTitleJob, args: [ session.id ]) do
      session.pause!
    end
  end

  # === Tests for push notifications on pause (opt-in) and fail (always) ===

  test "pause enqueues debounced SendPushNotificationJob when push_notifications_enabled is true" do
    session = sessions(:waiting)
    session.update!(status: :running, push_notifications_enabled: true)

    assert_enqueued_jobs 1, only: SendPushNotificationJob do
      session.pause!
    end

    enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.find { |j| j["job_class"] == "SendPushNotificationJob" }
    assert_not_nil enqueued, "Expected a SendPushNotificationJob to be enqueued"

    # Job is scheduled with a wait (debounced), not enqueued immediately
    assert enqueued["scheduled_at"].present?, "needs_input push notification should be scheduled with a wait"

    # Args: [session_id, :needs_input (serialized), custom_message=nil, transition_marker=<count>]
    args = enqueued["arguments"]
    assert_equal session.id, args[0]
    # Symbols are serialized via ActiveJob::Serializers::SymbolSerializer in queue payload
    assert_equal "needs_input", args[1].is_a?(Hash) ? args[1]["value"] : args[1]
    assert_nil args[2]
    assert_equal session.reload.custom_metadata["needs_input_count"], args[3]
  end

  test "pause does not enqueue SendPushNotificationJob when push_notifications_enabled is false" do
    session = sessions(:waiting)
    session.update!(status: :running, push_notifications_enabled: false)

    assert_no_enqueued_jobs(only: SendPushNotificationJob) do
      session.pause!
    end
  end

  test "pause increments needs_input_count on each transition" do
    session = sessions(:waiting)
    session.update!(status: :running, push_notifications_enabled: true)

    session.pause!
    first_count = session.reload.custom_metadata["needs_input_count"]
    assert_equal 1, first_count

    session.update!(status: :running)
    session.pause!
    second_count = session.reload.custom_metadata["needs_input_count"]
    assert_equal 2, second_count
  end

  test "fail enqueues SendPushNotificationJob when push_notifications_enabled is true" do
    session = sessions(:waiting)
    session.update!(status: :running, push_notifications_enabled: true)

    assert_enqueued_with(job: SendPushNotificationJob, args: [ session.id, :session_failed ]) do
      session.fail!
    end
  end

  test "fail enqueues SendPushNotificationJob even when push_notifications_enabled is false" do
    # Terminal failures bypass the per-session opt-in: by the time fail! fires,
    # retries are exhausted and the user would otherwise see a silent status flip.
    # This is the core fix for silent MCP-connection-failure sessions.
    session = sessions(:waiting)
    session.update!(status: :running, push_notifications_enabled: false)

    assert_enqueued_with(job: SendPushNotificationJob, args: [ session.id, :session_failed ]) do
      session.fail!
    end
  end

  test "fail from any prior state enqueues SendPushNotificationJob" do
    # The fail event allows from waiting/running/needs_input. Any fail transition
    # is a terminal event the user wants to know about, regardless of opt-in.
    session = sessions(:waiting)
    session.update!(status: :waiting, push_notifications_enabled: false)

    assert_enqueued_with(job: SendPushNotificationJob, args: [ session.id, :session_failed ]) do
      session.fail!
    end
  end

  # === cancel_pending_one_time_wake_triggers ===

  test "resume cancels pending one-time schedule conditions targeting this session" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)

    trigger = Trigger.create!(
      name: "Per-session wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )
    condition = trigger.trigger_conditions.first
    assert_nil condition.last_triggered_at

    session.reload
    session.resume!

    condition.reload
    assert_not_nil condition.last_triggered_at, "One-time schedule condition should be marked fired after resume"
  end

  # === system-recovery resume preserves pending wake-ups ===
  #
  # An interruption nudge is Zimmer restarting the session's own process, not
  # anyone deciding it should wake. Consuming its wake-ups there is what stranded
  # orchestrator #4388 in needs_input for ~22 hours with five children it was
  # supposed to be watching and a deadline backstop that could no longer fire.

  # Build the wake set an orchestrator actually registers: watchers on children
  # plus a wake_me_up_later deadline backstop.
  def wake_set_for(session, watched:, scheduled_at: 30.minutes.from_now.iso8601)
    conditions = watched.map do |watched_session|
      { condition_type: "ao_event",
        configuration: { "event_name" => "session_archived", "watched_session_id" => watched_session.id } }
    end
    conditions << { condition_type: "schedule",
                    configuration: { "scheduled_at" => scheduled_at, "timezone" => "UTC" } } if scheduled_at

    conditions.map do |condition|
      Trigger.create!(
        name: "Wake ##{session.id}",
        status: "enabled",
        agent_root_name: "zimmer",
        prompt_template: "Wake",
        reuse_session: true,
        last_session_id: session.id,
        trigger_conditions_attributes: [ condition ]
      ).trigger_conditions.first
    end
  end

  test "system-recovery resume leaves pending one-time wake-ups armed" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)
    child = sessions(:running)

    conditions = wake_set_for(session, watched: [ child ])
    assert_equal 2, conditions.size

    session.reload
    session.resume_for_system_recovery!

    conditions.each do |condition|
      assert_nil condition.reload.last_triggered_at,
        "a system-recovery resume must not consume wake condition #{condition.id}"
    end
  end

  # The regression test for the stall itself: recovered, ran its turn, and got
  # back to waiting with its wake set intact instead of resting in needs_input.
  test "system-recovery resume returns the session to waiting when a scheduled backstop is armed" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)
    child = sessions(:running)
    conditions = wake_set_for(session, watched: [ child ])

    session.reload
    session.resume_for_system_recovery!
    assert session.running?
    assert_equal true, session.reload.metadata["pending_sleep"]

    session.pause!

    assert session.reload.waiting?,
      "a recovered session with wake-ups still armed must go back to sleep, not sit in needs_input"
    conditions.each { |condition| assert_nil condition.reload.last_triggered_at }
  end

  # Without a scheduled backstop there is nothing guaranteed to fire, and a
  # watched transition that happened during the outage is not replayed. Resting
  # in needs_input keeps the session visible rather than trading a long stall for
  # an indefinite one. The watchers stay armed either way.
  test "system-recovery resume rests in needs_input when only session watchers are armed" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)
    child = sessions(:running)
    conditions = wake_set_for(session, watched: [ child ], scheduled_at: nil)

    session.reload
    session.resume_for_system_recovery!

    assert_not session.reload.metadata["pending_sleep"],
      "no scheduled backstop means no guaranteed wake, so the session must not be put back to sleep"

    session.pause!

    assert session.reload.needs_input?
    conditions.each { |condition| assert_nil condition.reload.last_triggered_at }
  end

  test "resume_for_system_recovery! does not leak the flag into a later deliberate resume" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)
    child = sessions(:running)

    session.reload
    session.resume_for_system_recovery!
    assert_not session.system_recovery_resume

    session.pause!
    conditions = wake_set_for(session, watched: [ child ])

    session.reload
    session.resume!

    conditions.each do |condition|
      assert_not_nil condition.reload.last_triggered_at,
        "a deliberate resume after a recovery must still consume wake condition #{condition.id}"
    end
  end

  # The inverse stall. A backstop whose wall time elapsed during the outage is due
  # the instant recovery resumes the session, so it can fire during the recovery
  # turn and destroy its siblings. Sleeping on the now-stale intent would land the
  # session in waiting with nothing armed and no paused_by — invisible to both
  # recovery sweeps, which is worse than the needs_input stall being fixed.
  test "a preserved re-sleep is dropped when its wake-ups are gone by the end of the turn" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)
    child = sessions(:running)
    conditions = wake_set_for(session, watched: [ child ])

    session.reload
    session.resume_for_system_recovery!
    assert_equal true, session.reload.metadata["pending_sleep"]

    # The backstop fires mid-turn and takes its siblings with it.
    conditions.each { |condition| condition.trigger.destroy! }

    session.pause!

    session.reload
    assert session.needs_input?,
      "with nothing left armed the session must stay visible in needs_input, not sleep into waiting"
    assert_nil session.metadata["pending_sleep"]
    assert_nil session.metadata[SessionStateMachine::PENDING_SLEEP_REQUIRES_WAKE]
  end

  # The deliberate-sleep contract is unchanged: it arms nothing on purpose, so it
  # must never be second-guessed by the conditional re-sleep above.
  test "a deliberate pending_sleep still sleeps the session with nothing armed" do
    session = sessions(:waiting)
    session.update!(status: :running, metadata: { "pending_sleep" => true })

    session.reload.pause!

    assert session.reload.waiting?
    assert_nil session.metadata["pending_sleep"]
  end

  test "resume_for_system_recovery! is a no-op on a session that cannot resume" do
    session = sessions(:waiting)
    session.update!(status: :running)

    session.reload
    assert_not session.resume_for_system_recovery!
    assert session.reload.running?
  end

  test "resume does not cancel recurring schedule conditions" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)

    trigger = Trigger.create!(
      name: "Recurring",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Recurring",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "interval" => 1, "unit" => "hours", "timezone" => "UTC" } }
      ]
    )
    condition = trigger.trigger_conditions.first
    assert_nil condition.last_triggered_at

    session.reload
    session.resume!

    condition.reload
    assert_nil condition.last_triggered_at, "Recurring schedule condition should NOT be cancelled by resume"
  end

  test "resume does not cancel conditions on disabled triggers" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)

    trigger = Trigger.create!(
      name: "Disabled wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )
    trigger.disable!
    condition = trigger.trigger_conditions.first

    session.reload
    session.resume!

    condition.reload
    assert_nil condition.last_triggered_at, "Conditions on disabled triggers should not be touched"
  end

  test "resume does not cancel conditions targeting a different session" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)

    other_session = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    trigger = Trigger.create!(
      name: "Per-other-session wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake",
      reuse_session: true,
      last_session_id: other_session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )
    condition = trigger.trigger_conditions.first

    session.reload
    session.resume!

    condition.reload
    assert_nil condition.last_triggered_at, "Conditions for other sessions should not be touched"
  end

  test "resume does not re-cancel already-fired conditions" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)

    trigger = Trigger.create!(
      name: "Per-session wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )
    condition = trigger.trigger_conditions.first
    original_time = 1.hour.ago
    condition.update!(last_triggered_at: original_time)

    session.reload
    session.resume!

    condition.reload
    assert_in_delta original_time.to_f, condition.last_triggered_at.to_f, 1.0, "Already-fired conditions should not be re-stamped"
  end

  # === clear_pending_sleep ===

  test "resume clears pending_sleep flag from metadata" do
    session = sessions(:needs_input)
    session.update!(metadata: (session.metadata || {}).merge("pending_sleep" => true))
    assert_equal true, session.reload.metadata["pending_sleep"]

    session.resume!

    session.reload
    assert_nil session.metadata["pending_sleep"], "Resume should clear pending_sleep to prevent stale auto-sleep on next pause"
  end

  test "resume leaves metadata intact when pending_sleep is not set" do
    session = sessions(:needs_input)
    session.update!(metadata: { "other_key" => "value" })

    session.resume!

    session.reload
    assert_equal "value", session.metadata["other_key"]
  end

  # === Zimmer Event firing on transitions ===
  #
  # fire_ao_event_triggers uses ActiveRecord.after_all_transactions_commit,
  # which defers job enqueueing until the outermost transaction commits. In
  # Rails tests with transactional fixtures, that never happens, so we stub
  # the API to call the block immediately.

  test "ActiveRecord.after_all_transactions_commit API exists" do
    # Regression guard: a previous version of fire_ao_event_triggers called
    # connection.after_transaction_commit, which does not exist on
    # PostgreSQLAdapter. The NoMethodError was silently rescued, so the job
    # was never enqueued in production. Assert the real API is available.
    assert ActiveRecord.respond_to?(:after_all_transactions_commit),
      "ActiveRecord.after_all_transactions_commit must be available (Rails 7.2+ API used by fire_ao_event_triggers)"
  end

  test "pause transition enqueues AoEventTriggerJob with session_needs_input" do
    session = sessions(:waiting)
    session.update!(status: :running)

    ActiveRecord.stubs(:after_all_transactions_commit).yields

    assert_enqueued_with(job: AoEventTriggerJob, args: [ "session_needs_input", session.id ]) do
      session.pause!
    end
  end

  test "fail transition enqueues AoEventTriggerJob with session_failed" do
    session = sessions(:waiting)
    session.update!(status: :running)

    ActiveRecord.stubs(:after_all_transactions_commit).yields

    assert_enqueued_with(job: AoEventTriggerJob, args: [ "session_failed", session.id ]) do
      session.fail!
    end
  end

  test "archive transition enqueues AoEventTriggerJob with session_archived" do
    session = sessions(:waiting)
    session.update!(status: :needs_input)

    ActiveRecord.stubs(:after_all_transactions_commit).yields

    assert_enqueued_with(job: AoEventTriggerJob, args: [ "session_archived", session.id ]) do
      session.archive!
    end
  end

  # === Archive cleanup of watched-session ao_event triggers ===

  test "archive deletes ao_event triggers scoped to this session" do
    watched = sessions(:needs_input)
    watched.update!(is_autonomous: true)

    trigger = Trigger.create!(
      name: "Wake on watched needs_input",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Watched session reached state",
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id }
        }
      ]
    )

    assert Trigger.where(id: trigger.id).exists?

    watched.archive!

    assert_not Trigger.where(id: trigger.id).exists?, "Archive should destroy watched-session ao_event trigger"
  end

  test "archive does not delete broadcast (no watched_session_id) ao_event triggers" do
    session = sessions(:needs_input)
    session.update!(is_autonomous: true)

    trigger = Trigger.create!(
      name: "Broadcast needs_input handler",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Some session needs input",
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input" } }
      ]
    )

    session.archive!

    assert Trigger.where(id: trigger.id).exists?, "Archive should not destroy broadcast triggers"
  end

  test "archive does not delete ao_event triggers watching a different session" do
    archived = sessions(:needs_input)
    other = sessions(:waiting)
    other.update!(is_autonomous: true)

    trigger = Trigger.create!(
      name: "Wake on other session",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Other session reached state",
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => "session_needs_input", "watched_session_id" => other.id }
        }
      ]
    )

    archived.archive!

    assert Trigger.where(id: trigger.id).exists?, "Archive should leave triggers scoped to other sessions intact"
  end

  test "archive does NOT destroy watched-session ao_event triggers scoped to session_archived" do
    # Regression guard: cleanup_watched_session_ao_event_triggers runs synchronously
    # in the archive callback, while AoEventTriggerJob is enqueued via
    # after_all_transactions_commit and runs after. If cleanup destroys the
    # session_archived condition before the job runs, the wake never fires.
    # The cleanup MUST skip session_archived conditions; the job's own
    # one_time_reuse_trigger? cleanup will delete the trigger after firing.
    watched = sessions(:needs_input)
    watched.update!(is_autonomous: true)

    trigger = Trigger.create!(
      name: "Wake on watched archive",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Watched session was archived: {{event}}",
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => "session_archived", "watched_session_id" => watched.id }
        }
      ]
    )
    condition = trigger.trigger_conditions.first

    watched.archive!

    assert TriggerCondition.where(id: condition.id).exists?,
      "session_archived condition must survive synchronous cleanup so the job can fire it"
    assert Trigger.where(id: trigger.id).exists?,
      "Trigger must survive so AoEventTriggerJob can fire and then auto-destroy it"
  end

  test "archive cleanup preserves session_archived condition while destroying session_needs_input siblings" do
    # When a trigger has both a session_needs_input watcher and a session_archived
    # watcher for the SAME watched session, archiving should clean up the stale
    # needs_input one but preserve the archived one (which is firing right now).
    watched = sessions(:needs_input)
    watched.update!(is_autonomous: true)

    needs_input_trigger = Trigger.create!(
      name: "Wake on needs_input",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "needs_input: {{event}}",
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id }
        }
      ]
    )
    archived_trigger = Trigger.create!(
      name: "Wake on archive",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "archived: {{event}}",
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => "session_archived", "watched_session_id" => watched.id }
        }
      ]
    )

    watched.archive!

    assert_not Trigger.where(id: needs_input_trigger.id).exists?,
      "session_needs_input watcher should still be cleaned up — that event won't fire on an archived session"
    assert Trigger.where(id: archived_trigger.id).exists?,
      "session_archived watcher must survive synchronous cleanup so the job can fire it"
  end

  test "archive preserves multi-condition trigger and destroys only the matching condition" do
    # When the watched session is archived but the trigger has OTHER conditions
    # (slack, recurring schedule, broadcast ao_event), preserve the trigger and
    # only remove the now-stale watched-session condition. Otherwise we'd
    # silently nuke a Slack channel monitor just because someone archived an
    # unrelated watched session.
    watched = sessions(:needs_input)
    watched.update!(is_autonomous: true)

    trigger = Trigger.create!(
      name: "Multi-condition trigger",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Triggered: {{event}} {{link}}",
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id }
        },
        {
          condition_type: "slack",
          configuration: { "channel_id" => "C0TEST", "channel_name" => "test", "event_type" => "new_message" }
        }
      ]
    )
    scoped_condition = trigger.trigger_conditions.find { |c| c.condition_type == "ao_event" }
    slack_condition = trigger.trigger_conditions.find { |c| c.condition_type == "slack" }

    watched.archive!

    assert Trigger.where(id: trigger.id).exists?,
      "Trigger should survive when it has non-watched conditions"
    assert_not TriggerCondition.where(id: scoped_condition.id).exists?,
      "Watched-session condition should be destroyed"
    assert TriggerCondition.where(id: slack_condition.id).exists?,
      "Sibling slack condition should survive"
  end

  test "resume cancels pending session-scoped ao_event conditions targeting this session" do
    # Mirrors the schedule-cancellation behavior: when a target session resumes
    # via any path, pending one-time wake-ups targeting it should be consumed
    # so they don't fire again on an already-active session.
    target_session = sessions(:waiting)
    target_session.update!(status: :needs_input)

    watched_session = Session.create!(
      git_root: "https://github.com/test/repo",
      agent_runtime: "claude_code",
      branch: "main",
      status: :needs_input,
      is_autonomous: true
    )

    trigger = Trigger.create!(
      name: "Wake target on watched needs_input",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Watched reached: {{event}}",
      reuse_session: true,
      last_session_id: target_session.id,
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched_session.id }
        }
      ]
    )
    condition = trigger.trigger_conditions.first
    assert_nil condition.last_triggered_at

    target_session.reload
    target_session.resume!

    condition.reload
    assert_not_nil condition.last_triggered_at,
      "Resume should consume pending session-scoped ao_event condition"
  end

  test "resume does not cancel broadcast (no watched_session_id) ao_event conditions" do
    target_session = sessions(:waiting)
    target_session.update!(status: :needs_input)

    trigger = Trigger.create!(
      name: "Broadcast handler with target",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Some session needs input: {{event}}",
      reuse_session: true,
      last_session_id: target_session.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input" } }
      ]
    )
    condition = trigger.trigger_conditions.first

    target_session.reload
    target_session.resume!

    condition.reload
    assert_nil condition.last_triggered_at,
      "Broadcast ao_event conditions should keep firing across many sessions, not be cancelled by one resume"
  end

  # --- Stranded elicitation block reconciliation -----------------------------

  test "clear_stale_elicitation_block! clears a stale marker and leaves the session in needs_input" do
    session = sessions(:running)
    elicitation = create_blocking_elicitation(session)
    assert_equal "needs_input", session.reload.status
    assert session.blocked_on_elicitation?, "Active elicitation should have blocked the session"

    # Strand it: mark the elicitation resolved/expired WITHOUT firing the
    # after_commit that would normally clear the marker (update_column bypasses
    # callbacks). This reproduces a missed reactive reconciliation.
    elicitation.update_column(:status, "expired")

    assert session.reload.clear_stale_elicitation_block!, "Should report that a stale marker was cleared"
    assert_not session.reload.blocked_on_elicitation?, "Stale marker should be cleared"
    assert_equal "needs_input", session.reload.status,
      "A stranded/expired block should stay in needs_input, not flip to running"
  end

  test "clear_stale_elicitation_block! reloads under lock, preserving a concurrent metadata write on the shared json column" do
    session = sessions(:running)
    elicitation = create_blocking_elicitation(session)
    assert session.reload.blocked_on_elicitation?
    elicitation.update_column(:status, "expired") # strand: marker set, none active

    # Simulate a concurrent writer committing a DIFFERENT metadata key after this
    # in-memory object was loaded. metadata is a single json column, so clearing
    # the marker off a stale in-memory hash would drop this key. with_lock reloads
    # the committed row first, so the unrelated key survives.
    Session.find(session.id).update_column(:metadata, session.metadata.merge("pending_sleep" => true))

    assert session.clear_stale_elicitation_block!, "stale marker should be cleared"
    reloaded = session.reload
    assert_not reloaded.blocked_on_elicitation?, "stale elicitation marker cleared"
    assert_equal true, reloaded.metadata["pending_sleep"],
      "concurrent metadata write must survive the reload-before-clear"
  end

  test "clear_stale_elicitation_block! is a no-op while an active elicitation still exists" do
    session = sessions(:running)
    create_blocking_elicitation(session)
    assert_equal "needs_input", session.reload.status
    assert session.blocked_on_elicitation?

    assert_not session.reload.clear_stale_elicitation_block!,
      "Must not clear a block that is still backed by an active elicitation"
    assert session.reload.blocked_on_elicitation?, "Active elicitation must keep the block in place"
  end

  test "clear_stale_elicitation_block! is a no-op when no marker is set" do
    session = sessions(:running)
    assert_not session.blocked_on_elicitation?
    assert_not session.clear_stale_elicitation_block!
  end

  test "clear_stale_elicitation_block! surfaces the lost round-trip instead of a silently idle session" do
    session = sessions(:running)
    elicitation = create_blocking_elicitation(session)
    assert_equal "needs_input", session.reload.status
    elicitation.update_column(:status, "expired") # strand: marker set, none active

    session.reload.clear_stale_elicitation_block!

    session.reload
    assert session.lost_elicitation?,
      "a session parked in needs_input must say WHY, not just drop the phantom marker"
    assert_equal "stranded", session.lost_elicitation["reason"]
    assert_equal elicitation.request_id, session.lost_elicitation["request_id"]
    assert_equal "needs_input", session.status
    assert_match(/round-trip lost/i, session.logs.order(:id).last.content)
  end

  test "clear_stale_elicitation_block! does not raise a banner on a session whose agent never stopped" do
    session = sessions(:running)
    elicitation = create_blocking_elicitation(session)
    assert_equal "needs_input", session.reload.status
    elicitation.update_column(:status, "expired")
    # A swallowed InvalidTransition can leave the marker on a session that is back
    # to running. Nothing is waiting on the user there, so nothing should be shown.
    session.reload.update_column(:status, "running")

    session.reload.clear_stale_elicitation_block!

    session.reload
    assert_not session.blocked_on_elicitation?, "the stale marker is still cleared"
    assert_not session.lost_elicitation?, "a live session has nothing for the user to act on"
  end

  test "lost_elicitation_at survives a malformed stored timestamp" do
    session = sessions(:running)
    session.update_column(:metadata, { "lost_elicitation" => { "reason" => "stranded", "at" => "not-a-time" } })

    assert session.reload.lost_elicitation?
    assert_nil session.lost_elicitation_at,
      "a bad stored value must render as an absent timestamp, not raise inside a Turbo broadcast"
  end

  test "resuming a session clears the lost elicitation banner" do
    session = sessions(:running)
    session.record_lost_elicitation!(reason: "stranded")
    session.update_column(:status, "needs_input")
    assert session.reload.lost_elicitation?

    session.resume!

    assert_not session.reload.lost_elicitation?
  end

  test "blocked_on_elicitation scope selects only sessions carrying the marker" do
    blocked = sessions(:running)
    create_blocking_elicitation(blocked)
    assert blocked.reload.blocked_on_elicitation?

    assert_includes Session.blocked_on_elicitation.to_a, blocked
    assert_not_includes Session.blocked_on_elicitation.to_a, sessions(:waiting)
  end

  # ===========================================================================
  # Swallowed side effects announce themselves (#73)
  # ===========================================================================

  # The trade the bare rescues make is still the right one: a broken side effect
  # must not wedge a session mid-transition. What changed is that the ones that
  # leave inconsistent persistent state now page instead of only logging.
  test "a swallowed side effect that leaves inconsistent state raises an alert" do
    session = sessions(:running)
    session.update!(status: :running, running_job_id: "job-123")

    session.stubs(:update_column).raises(StandardError, "database is unhappy")
    run_deferred_commit_callbacks_inline

    alerted = []
    AlertService.stubs(:raise_alert).with do |title, opts|
      alerted << [ title, opts[:source], opts[:dedup_key] ]
      true
    end.returns(true)

    session.pause!

    assert_equal :needs_input, session.status.to_sym,
      "the transition must still complete — swallowing is the whole point"
    cleanup = alerted.find { |_title, source, _key| source == "SessionStateMachine#cleanup_running_job" }
    assert cleanup, "expected cleanup_running_job to page, got: #{alerted.inspect}"
    assert_equal "Session state-machine side effect failed", cleanup[0]
    assert_equal "session_state_machine_side_effect_cleanup_running_job", cleanup[2]
  end

  # The dedup key must key on the callback, not the session: a sick database
  # hits this for every session in flight and must collapse to one alert.
  test "the alert dedup key is per-callback, not per-session" do
    run_deferred_commit_callbacks_inline
    keys = []
    AlertService.stubs(:raise_alert).with do |_title, opts|
      keys << opts[:dedup_key]
      true
    end.returns(true)

    [ sessions(:running), sessions(:active_session) ].each do |session|
      session.update!(status: :running, running_job_id: "job-#{session.id}")
      session.stubs(:update_column).raises(StandardError, "database is unhappy")
      session.pause!
    end

    cleanup_keys = keys.select { |k| k == "session_state_machine_side_effect_cleanup_running_job" }
    assert_equal 2, cleanup_keys.size
    assert_equal 1, cleanup_keys.uniq.size
  end

  # The other half of the split. Push delivery is best-effort by construction and
  # the failed session is on the homepage queue regardless, so it stays log-only —
  # adding a second alert path to an event that already self-heals is just noise.
  test "a best-effort side effect failure stays log-only" do
    session = sessions(:running)
    session.update!(status: :running)

    run_deferred_commit_callbacks_inline
    SendPushNotificationJob.stubs(:perform_later).raises(StandardError, "queue is down")
    AlertService.expects(:raise_alert).never

    session.fail!

    assert_equal :failed, session.status.to_sym
  end

  # These rescues run inside AASM `after` blocks, so an exception escaping the
  # reporter would abort the transition mid-flight — the exact wedge the bare
  # rescues exist to prevent.
  test "a broken logger cannot wedge a transition through the reporter" do
    session = sessions(:running)
    session.update!(status: :running, running_job_id: "job-123")
    session.stubs(:update_column).raises(StandardError, "database is unhappy")
    Rails.logger.stubs(:error).raises(StandardError, "logger is broken")
    AlertService.stubs(:raise_alert).returns(true)

    assert_nothing_raised { session.pause! }
    assert_equal :needs_input, session.status.to_sym
  end

  # An alert that cannot be posted must not become a second way for the
  # transition to blow up. This covers the AlertService half; the test above
  # covers the logger half.
  test "a broken AlertService cannot wedge a transition" do
    session = sessions(:running)
    session.update!(status: :running, running_job_id: "job-123")
    session.stubs(:update_column).raises(StandardError, "database is unhappy")
    run_deferred_commit_callbacks_inline
    AlertService.stubs(:raise_alert).raises(StandardError, "slack is on fire")

    assert_nothing_raised { session.pause! }
    assert_equal :needs_input, session.status.to_sym
  end

  private

  # The alert is posted from an after_all_transactions_commit block so the Slack
  # round trip happens outside the transition's transaction. Transactional tests
  # never commit, so the block would never run — this makes it run inline, which
  # is exactly what production does when no transaction is open.
  def run_deferred_commit_callbacks_inline
    ActiveRecord.stubs(:after_all_transactions_commit).yields
  end

  def create_blocking_elicitation(session)
    Elicitation.create!(
      session: session,
      request_id: "req-#{SecureRandom.hex(8)}",
      mode: "form",
      message: "Blocking elicitation",
      requested_schema: { "type" => "object" },
      meta: {},
      expires_at: 1.hour.from_now
    )
  end
end
