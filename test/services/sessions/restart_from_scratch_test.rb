# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Sessions::RestartFromScratchTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include AttachmentFixtures

  teardown { cleanup_stored_attachments! }

  def failed_before_setup_session(**attrs)
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "here is the screenshot, fix this",
      status: :failed,
      metadata: { "failure_reason" => "git_clone_failed" },
      **attrs
    )
  end

  # --- the happy path ---------------------------------------------------------

  test "resumes the session, clears its session_id and enqueues a fresh first turn" do
    session = failed_before_setup_session(session_id: SecureRandom.uuid)

    result = nil
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      result = Sessions::RestartFromScratch.call(session, actor: :web)
    end

    assert result.ok?
    assert_nil result.error
    assert_nil result.error_code
    assert_equal "running", session.reload.status
    assert_nil session.session_id
  end

  test "writes the two log rows the surfaces used to write themselves" do
    session = failed_before_setup_session

    Sessions::RestartFromScratch.call(session, actor: :api)

    assert session.logs.where(
      content: "Restarting session from scratch: re-running full setup pipeline " \
               "(git clone, MCP config, process spawn)"
    ).exists?
    assert session.logs.where(
      content: "Session resumed - status changed to running, full setup will be re-attempted"
    ).exists?
  end

  # --- the key set ------------------------------------------------------------
  #
  # RESTART_FROM_SCRATCH_KEYS is the default reset plus the setup artifacts plus
  # the spot-hold ladder. All three matter here: the artifacts describe a setup
  # attempt that failed partway through, and the ladder must not carry a held
  # session's backoff into a restart somebody asked for by name.

  test "clears the stale retry metadata, the setup artifacts and the spot-hold ladder" do
    session = failed_before_setup_session
    session.update!(metadata: session.metadata.merge(
      "clone_path" => "/tmp/half-a-clone",
      "working_directory" => "/tmp/half-a-clone",
      "runtime_started" => true,
      "process_pid" => 4242,
      "api_error_retry_count" => 3,
      "paused_by" => "recovery",
      SpotSessionHold::HELD_COUNT => 3,
      SpotSessionHold::HELD_AT => Time.current.iso8601,
      "api_error_last_checked_line" => 91
    ))

    Sessions::RestartFromScratch.call(session)

    metadata = session.reload.metadata
    Session::RESTART_FROM_SCRATCH_KEYS.each do |key|
      assert_nil metadata[key], "#{key} should have been cleared by a restart from scratch"
    end

    # The scan position is deliberately NOT in any of the reset sets: clearing it
    # makes the error scanner re-process errors it has already handled.
    assert_equal 91, metadata["api_error_last_checked_line"]
  end

  # --- running_job_id ---------------------------------------------------------
  #
  # The three copies this class replaced set running_job_id to nil and enqueued
  # without recording the new id, leaving the session `running` with no tracked
  # job. DeploymentRecoveryJob#orphaned_running_session? calls that orphaned with
  # no grace period, so a recovery pass landing in the window starts a second turn
  # against the session this restart just started.

  test "claims the enqueued job's id so the session is never running with no tracked job" do
    session = failed_before_setup_session
    enqueue = AgentSessionJob.method(:enqueue_new_session)
    job = nil

    AgentSessionJob.stub(:enqueue_new_session, ->(*args, **kwargs) { job = enqueue.call(*args, **kwargs) }) do
      assert Sessions::RestartFromScratch.call(session).ok?
    end

    assert job.job_id.present?
    assert_equal job.job_id, session.reload.running_job_id,
      "running_job_id closes the window where a session is running with no tracked job"
  end

  test "still reports success when the enqueue returns no job id" do
    session = failed_before_setup_session

    AgentSessionJob.stub(:enqueue_new_session, ->(*, **) { false }) do
      result = Sessions::RestartFromScratch.call(session)
      assert result.ok?
    end

    assert_equal "running", session.reload.status
    assert_nil session.running_job_id
  end

  # --- the attachments --------------------------------------------------------

  test "carries the attachments the first turn was created with" do
    session = failed_before_setup_session
    image = store_image_for(session)
    file = store_file_for(session, filename: "notes.txt", content: "read me")

    Sessions::RestartFromScratch.call(session)

    assert_enqueued_with(
      job: AgentSessionJob,
      args: [
        session.id, nil,
        {
          images: [ { path: image[:path], media_type: "image/png" } ],
          files: [ { path: file[:path], original_filename: "notes.txt", size: "read me".bytesize } ]
        }
      ]
    )
    assert session.logs.where("content LIKE ?", "%carrying 1 image and 1 file%").exists?
  end

  test "an unreadable attachment store costs the attachments, never the restart" do
    session = failed_before_setup_session
    store_image_for(session)

    ImageStorageService.stub(:stored_for, ->(*) { raise Errno::EACCES, "storage" }) do
      assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
        assert Sessions::RestartFromScratch.call(session).ok?
      end
    end

    assert_equal "running", session.reload.status
  end

  # --- refusals and failures --------------------------------------------------

  test "refuses a session with no git_root and records the refusal on its timeline" do
    session = failed_before_setup_session
    session.update_column(:git_root, nil)

    result = nil
    assert_no_enqueued_jobs(only: AgentSessionJob) do
      result = Sessions::RestartFromScratch.call(session.reload)
    end

    assert_not result.ok?
    assert_equal :no_git_root, result.error_code
    assert_equal "cannot restart from scratch: no git_root configured", result.error
    assert_equal "failed", session.reload.status
    assert session.logs.where(
      "content LIKE ?", "%cannot restart from scratch: no git_root configured%"
    ).exists?
  end

  # The behaviour change #508 asked for: the retry used to exist only in the web
  # copy. A dropped connection is a transport failure the caller should retry, so
  # it comes back as its own code rather than as an exception the surface has to
  # guess at.
  test "retries a dropped connection and reports database_unavailable once the attempts are spent" do
    session = failed_before_setup_session
    attempts = 0

    AgentSessionJob.stub(:enqueue_new_session, ->(*, **) {
      attempts += 1
      raise ActiveRecord::ConnectionNotEstablished, "connection lost"
    }) do
      Sessions::RestartFromScratch.any_instance.stubs(:sleep)
      result = Sessions::RestartFromScratch.call(session)

      assert_not result.ok?
      assert_equal :database_unavailable, result.error_code
      assert_match(/high server activity/, result.error)
    end

    assert_equal 3, attempts, "the block should have been retried up to DatabaseRetry's attempt limit"
    assert_equal "failed", session.reload.status, "the transaction must have rolled back"
  end

  # A rollback does not undo what AASM already did to the in-memory object, so an
  # attempt that fails AFTER `resume!` leaves `status` dirty as an unpersisted
  # `running`. Without the re-read, the next attempt writes that through `update!`
  # — no state machine — and then finds `may_resume?` false and skips `resume!`
  # altogether, dropping every callback it carries. `paused_by` would still be
  # cleared (it is in the key set), but `pending_sleep` is in none of the reset
  # sets and only `clear_pending_sleep` removes it: left behind, it drops the
  # session to `waiting` at its next pause.
  test "a retry that succeeds on the second attempt still runs the resume callbacks" do
    session = failed_before_setup_session
    session.merge_metadata!("pending_sleep" => true)
    attempts = 0
    enqueue = AgentSessionJob.method(:enqueue_new_session)

    AgentSessionJob.stub(:enqueue_new_session, ->(*args, **kwargs) {
      attempts += 1
      raise ActiveRecord::ConnectionNotEstablished, "connection lost" if attempts == 1

      enqueue.call(*args, **kwargs)
    }) do
      Sessions::RestartFromScratch.any_instance.stubs(:sleep)
      assert Sessions::RestartFromScratch.call(session).ok?
    end

    assert_equal 2, attempts
    session.reload
    assert_equal "running", session.status
    assert_nil session.metadata["pending_sleep"],
      "the second attempt skipped resume!, so clear_pending_sleep never ran"
    assert session.logs.where(content: "[State Machine] Session resumed").exists?,
      "the resume event did not fire on the successful attempt"
  end

  test "reports any other failure with its message and records it on the timeline" do
    session = failed_before_setup_session

    AgentSessionJob.stub(:enqueue_new_session, ->(*, **) { raise "the queue is on fire" }) do
      result = Sessions::RestartFromScratch.call(session)

      assert_not result.ok?
      assert_equal :failed, result.error_code
      assert_equal "the queue is on fire", result.error
    end

    assert_equal "failed", session.reload.status
    assert session.logs.where("content LIKE ?", "%Error restarting session from scratch%").exists?
  end
end
