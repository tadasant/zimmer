# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class DeferredCloneCleanupJobTest < ActiveJob::TestCase
  setup do
    @session = sessions(:running)
    @session.logs.destroy_all
    @clone_path = "/tmp/test-clone-deferred-#{SecureRandom.hex(4)}"
    FileUtils.mkdir_p(@clone_path)
    @archived_at = Time.current
    @session.update!(
      status: :archived,
      archived_at: @archived_at,
      trash_after: 4.days.from_now,
      metadata: { "clone_path" => @clone_path }
    )

    # The job now stats the scratch base to decide whether anything is still
    # retained, so every test in this file needs it pinned to an empty tmpdir —
    # otherwise the result depends on whatever happens to be in the host's real
    # ~/.zimmer/session-scratch, and the suite would rm_rf outside its sandbox.
    @scratch_env = ENV["AGENT_SCRATCH_DIR"]
    @scratch_base = Dir.mktmpdir("deferred-scratch")
    ENV["AGENT_SCRATCH_DIR"] = @scratch_base
  end

  teardown do
    GoodJob::CurrentThread.execution_interrupted = nil
    @scratch_env.nil? ? ENV.delete("AGENT_SCRATCH_DIR") : ENV["AGENT_SCRATCH_DIR"] = @scratch_env
    FileUtils.remove_entry(@scratch_base) if @scratch_base && Dir.exist?(@scratch_base)
    FileUtils.rm_rf(@clone_path) if @clone_path && File.directory?(@clone_path)
  end

  test "cleans up clone and clears trash_after when clone is clean and nothing else is retained" do
    assert File.directory?(@clone_path), "Clone should exist before cleanup"

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert_not File.directory?(@clone_path), "Clone should be deleted after cleanup"

    # trash_after should be cleared for clean clones (no artifacts to retain)
    @session.reload
    assert_nil @session.trash_after, "trash_after should be cleared for clean clones"

    # Verify log was created
    log = @session.logs.find_by("content LIKE ?", "%Clone deleted%")
    assert_not_nil log
    assert_equal "info", log.level
    assert_includes log.content, "no unpushed state"
  end

  # A status-summary fork of a session whose clone was already reclaimed gets a
  # SCAFFOLDED clone — an empty directory that is not a git repository at all. It
  # has to come back on this path like any other, because it is the only thing
  # that reclaims it; a fork left holding one would sit on disk forever, hidden
  # from every operator list.
  test "reclaims a scaffolded clone that is not a git repository" do
    @session.update!(metadata: @session.metadata.merge("clone_scaffolded" => true))
    assert_not File.directory?(File.join(@clone_path, ".git")), "the scaffold is not a repository"

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert_not File.directory?(@clone_path), "a scaffolded clone is reclaimed like any other"
    assert_nil @session.reload.trash_after, "there is no unpushed state to hold retention open for"
  end

  test "leaves the durable per-session scratch dir intact when reaping the clone" do
    scratch_path = SessionScratchDirectory.ensure_for(@session.id)
    handoff = File.join(scratch_path, "state.txt")
    File.write(handoff, "cross-step state")

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert_not File.directory?(@clone_path), "clone should still be reaped"
    assert File.exist?(handoff), "scratch contents must survive the undo window so unarchive can find them"
    assert_equal "cross-step state", File.read(handoff)
  end

  test "holds trash_after open for the retention period when scratch is retained" do
    SessionScratchDirectory.ensure_for(@session.id)

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    @session.reload
    assert_not_nil @session.trash_after,
      "trash_after must stay set so EmptyTrashJob eventually reaps scratch and StaleCloneCleanupJob leaves it alone"
    # Measured from the archive, not from when the job happened to run.
    assert_in_delta @archived_at + SessionStateMachine::TRASH_RETENTION_PERIOD, @session.trash_after, 5
  end

  test "leaves scratch intact even when there is no clone on disk" do
    scratch_path = SessionScratchDirectory.ensure_for(@session.id)
    FileUtils.rm_rf(@clone_path) # no clone to reap

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert Dir.exist?(scratch_path), "scratch dir should survive even when there is no clone"
    @session.reload
    assert_not_nil @session.trash_after, "a session with only scratch left still needs a trash deadline"
  end

  test "leaves durable prompt attachments intact when reaping the clone" do
    # Scratch stays absent (setup pins an empty base), so only the attachments
    # are retained here.
    file_service = FileStorageService.new(session_id: @session.id)
    image_service = ImageStorageService.new(session_id: @session.id)
    begin
      file_service.store(data: "notes", filename: "notes.md")
      png = [ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ].pack("C*") + ("x" * 32)
      image_service.store(data: Base64.strict_encode64(png), filename: "shot.png")

      DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

      assert Dir.exist?(file_service.session_dir), "file attachments should outlive the clone"
      assert Dir.exist?(image_service.session_dir), "image attachments should outlive the clone"
      @session.reload
      assert_not_nil @session.trash_after, "retained attachments must hold the trash deadline open"
    ensure
      file_service.cleanup!
      image_service.cleanup!
    end
  end

  test "skips cleanup when session is no longer archived" do
    # Unarchive the session
    @session.unarchive_to_failed!
    assert_not @session.archived?, "Session should not be archived"

    assert File.directory?(@clone_path), "Clone should exist before job runs"

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    # Clone should still exist because session was unarchived
    assert File.directory?(@clone_path), "Clone should NOT be deleted when session is unarchived"
  end

  test "skips cleanup when session was re-archived with different timestamp" do
    original_archived_at = @archived_at

    # Update archived_at to be more than 1 second in the future (outside tolerance)
    new_archived_at = original_archived_at + 2.seconds
    @session.update!(archived_at: new_archived_at)

    assert File.directory?(@clone_path), "Clone should exist before job runs"

    # Run job with the original archived_at timestamp
    DeferredCloneCleanupJob.perform_now(@session.id, original_archived_at.iso8601)

    # Clone should still exist because the timestamps don't match
    assert File.directory?(@clone_path), "Clone should NOT be deleted when session was re-archived"
  end

  test "skips cleanup when session does not exist" do
    non_existent_id = 999999

    assert_nothing_raised do
      DeferredCloneCleanupJob.perform_now(non_existent_id, @archived_at.iso8601)
    end

    assert File.directory?(@clone_path), "Clone should not be affected"
  end

  test "handles session deleted after job was scheduled" do
    session_id = @session.id
    archived_at = @archived_at.iso8601

    @session.destroy!

    assert_nothing_raised do
      DeferredCloneCleanupJob.perform_now(session_id, archived_at)
    end

    assert File.directory?(@clone_path), "Clone should not be affected when session is deleted"
  end

  test "skips cleanup when clone path does not exist" do
    FileUtils.rm_rf(@clone_path)

    assert_nothing_raised do
      DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)
    end

    # trash_after should be cleared since there's nothing to preserve
    @session.reload
    assert_nil @session.trash_after
  end

  test "skips cleanup when clone path is nil" do
    @session.update!(metadata: {})

    assert_nothing_raised do
      DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)
    end

    @session.reload
    assert_nil @session.trash_after
  end

  test "handles invalid archived_at timestamp gracefully" do
    assert File.directory?(@clone_path), "Clone should exist before job runs"

    assert_nothing_raised do
      DeferredCloneCleanupJob.perform_now(@session.id, "invalid-timestamp")
    end

    assert File.directory?(@clone_path), "Clone should NOT be deleted with invalid timestamp"
  end

  test "undo within window prevents cleanup" do
    assert File.directory?(@clone_path), "Clone should exist"

    @session.update!(archived_at: nil)
    @session.unarchive_to_failed!

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert File.directory?(@clone_path), "Clone should still exist after undo"
    assert_not @session.archived?, "Session should not be archived after undo"
  end

  test "cleanup delay constant is longer than undo window" do
    undo_window = 5.seconds
    assert DeferredCloneCleanupJob::CLEANUP_DELAY > undo_window,
      "Cleanup delay (#{DeferredCloneCleanupJob::CLEANUP_DELAY}) should be longer than undo window (#{undo_window})"
  end

  test "archive enqueues deferred cleanup job and sets trash_after" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      branch: "main",
      session_id: SecureRandom.uuid,
      status: :needs_input,
      archived_at: Time.current
    )
    clone_path = "/tmp/test-clone-schedule-#{SecureRandom.hex(4)}"
    FileUtils.mkdir_p(clone_path)
    session.update!(metadata: { "clone_path" => clone_path })

    # Archive SHOULD enqueue DeferredCloneCleanupJob
    assert_enqueued_with(job: DeferredCloneCleanupJob) do
      session.archive!
    end

    # Clone should still exist (preserved until deferred job runs)
    assert File.directory?(clone_path), "Clone should exist after archive"

    # trash_after should be set as safety net
    session.reload
    assert_not_nil session.trash_after, "trash_after should be set when session is archived"
    assert session.trash_after > Time.current, "trash_after should be in the future"
  ensure
    FileUtils.rm_rf(clone_path) if clone_path && File.directory?(clone_path)
  end

  # === Artifact preservation failure tests ===

  test "keeps clone intact when dirty state detected but artifact creation fails" do
    assert File.directory?(@clone_path), "Clone should exist before cleanup"
    # A deadline nothing else would produce, so the assertion below can only pass
    # if this branch wrote its own rather than inheriting archive's.
    @session.update_column(:trash_after, 1.hour.from_now)

    stub_failed_artifact_preservation

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    # Clone should NOT be deleted because artifact creation failed — it is now the
    # only copy of the session's unpushed work, and unarchive restores it directly.
    assert File.directory?(@clone_path), "Clone should be preserved when artifact creation fails"

    @session.reload
    assert_in_delta (@archived_at + SessionStateMachine::TRASH_RETENTION_PERIOD).to_f, @session.trash_after.to_f, 1,
      "the kept clone belongs to EmptyTrashJob for the full retention window"
    hold_log = @session.logs.find_by("content LIKE ?", "%Could not preserve unpushed artifacts%")
    assert_not_nil hold_log, "the user's only surface is the session log, so the hold has to appear there"
    assert_equal "warning", hold_log.level
  end

  # Regression for #653. The dirty check can read a tree that a concurrent
  # recursive delete is still walking — File.directory? says yes because rm_rf
  # unlinks children under the live path, and `git status` on the gutted tree
  # says dirty — and by the time preservation starts there is nothing left.
  #
  # That raised ENOENT out of create_artifacts, logged .error twice (the page in
  # the alert this fixes), and then held a four-day trash deadline open for a
  # clone that does not exist. A clone that is simply gone is not a failure to
  # preserve: there is nothing to preserve and nothing to keep.
  test "treats a clone that vanishes between the dirty check and preservation as nothing to preserve" do
    # The delete lands inside the dirty check, exactly where production's does.
    artifact_service = CloneArtifactService.new
    clone_path = @clone_path
    artifact_service.define_singleton_method(:check_dirty_state) do |path|
      FileUtils.rm_rf(clone_path)
      CloneArtifactService::DirtyCheckResult.new(
        dirty?: true, has_uncommitted?: true, has_unpushed_commits?: false,
        details: "uncommitted changes (3 files)"
      )
    end
    CloneArtifactService.expects(:new).returns(artifact_service)

    logged_errors = []
    Rails.logger.stub(:error, ->(message = nil) { logged_errors << message.to_s }) do
      DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)
    end

    assert_empty logged_errors, "a clone that is simply gone must not log at .error — that is the page"

    @session.reload
    assert_nil @session.trash_after,
      "nothing restorable is left, so nothing may hold this session in the trash for four days"
    assert_nil @session.logs.find_by("content LIKE ?", "%Could not preserve unpushed artifacts%"),
      "the user must not be told a clone is being kept for them when none exists"
  end

  # The flag alone must not be enough to skip the delete. If a clone_missing?
  # result ever arrives for a clone that IS on disk, taking the "nothing to
  # preserve" branch would strand it: no Docker teardown, no delete, trash_after
  # cleared, and nothing but StaleCloneCleanupJob's unpreserved sweep to reap it
  # an hour later. The branch checks the disk, so this falls through to the hold.
  test "holds a clone that is still on disk even if preservation reports it missing" do
    dirty_result = CloneArtifactService::DirtyCheckResult.new(
      dirty?: true, has_uncommitted?: true, has_unpushed_commits?: false, details: "uncommitted changes"
    )
    create_result = CloneArtifactService::CreateResult.new(
      success?: false, clone_missing?: true, error: "No such file or directory - git"
    )
    artifact_service = mock("artifact_service")
    artifact_service.expects(:check_dirty_state).with(@clone_path).returns(dirty_result)
    artifact_service.expects(:create_artifacts)
      .with(session_id: @session.id, clone_path: @clone_path).returns(create_result)
    CloneArtifactService.expects(:new).returns(artifact_service)

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert File.directory?(@clone_path), "a clone that is still there is the only copy of the work"
    @session.reload
    assert_in_delta (@archived_at + SessionStateMachine::TRASH_RETENTION_PERIOD).to_f, @session.trash_after.to_f, 1,
      "and it belongs to EmptyTrashJob for the full retention window, not to the one-hour stale sweep"
    assert_not_nil @session.logs.find_by("content LIKE ?", "%Could not preserve unpushed artifacts%")
  end

  # Preserving artifacts is not instant — a bundle, an `add -A` and a binary
  # diff over a whole working tree — and this job is the only clone deleter, so
  # the status it read before all that is stale by the time it deletes. Undo
  # inside that window puts a session back to work on this clone.
  test "leaves the clone alone when the session is unarchived while artifacts are being preserved" do
    session = @session
    artifact_service = CloneArtifactService.new
    artifact_service.define_singleton_method(:create_artifacts) do |session_id:, clone_path:|
      # The user hits Undo while the bundle is still being written.
      Session.find(session.id).unarchive_to_waiting!
      CloneArtifactService::CreateResult.new(success?: true, artifacts_path: "/tmp/artifacts-#{session_id}")
    end
    artifact_service.define_singleton_method(:check_dirty_state) do |_path|
      CloneArtifactService::DirtyCheckResult.new(
        dirty?: true, has_uncommitted?: true, has_unpushed_commits?: false, details: "uncommitted changes"
      )
    end
    CloneArtifactService.expects(:new).returns(artifact_service)

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert File.directory?(@clone_path),
      "the session is running against this clone again — deleting it is not something Undo can undo"
    assert_nil @session.reload.logs.find_by("content LIKE ?", "%Clone deleted%")
  end

  # Regression for #425: the failure branch used to just return, leaving
  # trash_after at whatever `archive` had managed to set. `set_trash_expiry` is
  # best-effort (its rescue is log-only), so a session can reach here with it
  # nil — and an archived session with no trash deadline is exactly what
  # StaleCloneCleanupJob reaps, unpreserved, an hour later, while this job's log
  # claimed the clone was being kept. The deadline is now written here.
  test "sets a trash deadline when artifact creation fails and archive never set one" do
    # A queue backed up past the stale threshold, on a session whose archive-time
    # trash_after never landed: the exact row StaleCloneCleanupJob claims.
    archived_at = 2.hours.ago
    @session.update_columns(archived_at: archived_at, trash_after: nil)
    stale_scope = StaleCloneCleanupJob.new.send(:archived_sessions_with_stale_clones)
    assert_includes stale_scope.pluck(:id), @session.id,
      "setup check: without a trash deadline this clone is the stale sweep's to reap"

    stub_failed_artifact_preservation

    DeferredCloneCleanupJob.perform_now(@session.id, archived_at.iso8601)

    assert File.directory?(@clone_path), "the clone is the only surviving copy of the work"
    @session.reload
    assert_in_delta (archived_at + SessionStateMachine::TRASH_RETENTION_PERIOD).to_f, @session.trash_after.to_f, 1,
      "a failed preservation must hold the clone for the reversible window, not leave it undeadlined"
    assert_not_includes stale_scope.pluck(:id), @session.id,
      "the stale sweep must no longer reap this clone unpreserved an hour after archive"
  end

  # === Mangled-clone accounting (issue #415) ===
  #
  # The archive-side mass-deletion guard logs at .warn, so it does not page per
  # defused clone. The rate is the live signal for #412, so every defusal has to
  # leave a durable, SQL-countable mark on the session — under exactly the keys
  # MangledCloneReportJob queries, which is why the constants come from there.

  test "records the mass-deletion guard's drop count on the session" do
    stub_artifact_preservation(dropped_deletions: 854)

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    @session.reload
    assert_equal 854, @session.metadata[MangledCloneReportJob::DROPPED_DELETIONS_KEY]
    stamp = @session.metadata[MangledCloneReportJob::DEFUSED_AT_KEY]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, stamp,
      "the reporter compares this as a string, so it must be fixed-width ISO8601 UTC")
    assert_equal "/tmp/artifacts", @session.metadata["artifacts_path"],
      "the marker must not displace the artifacts path written in the same update"
  end

  test "leaves no mangled-clone marker when the guard did not fire" do
    stub_artifact_preservation(dropped_deletions: nil)

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    @session.reload
    assert_not @session.metadata.key?(MangledCloneReportJob::DROPPED_DELETIONS_KEY),
      "an ordinary archive must not be counted as a mangled clone"
    assert_not @session.metadata.key?(MangledCloneReportJob::DEFUSED_AT_KEY)
  end

  # === Docker Compose cleanup tests ===

  test "calls DockerComposeCleanupService and still removes clone directory" do
    DockerComposeCleanupService.expects(:cleanup).with(@clone_path).returns(false)

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert_not File.directory?(@clone_path), "Clone should be deleted after cleanup"
  end

  test "logs Docker cleanup in session log when Docker resources were removed" do
    DockerComposeCleanupService.expects(:cleanup).with(@clone_path).returns(true)

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    log = @session.logs.find_by("content LIKE ?", "%Docker resources also removed%")
    assert_not_nil log, "Should log that Docker resources were removed"
  end

  test "does not mention Docker in log when no Docker resources existed" do
    DockerComposeCleanupService.expects(:cleanup).with(@clone_path).returns(false)

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    log = @session.logs.reload.last
    assert_not_nil log, "A cleanup log should have been created"
    assert_not_includes log.content, "Docker", "Should not mention Docker when no Docker resources existed"
  end

  test "proceeds with clone cleanup even if Docker cleanup raises an error" do
    DockerComposeCleanupService.expects(:cleanup).with(@clone_path).raises(StandardError, "unexpected docker error")

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert_not File.directory?(@clone_path), "Clone should be deleted even if Docker cleanup raises"
  end

  # A deploy interrupt must not end this job: ApplicationJob discards
  # GoodJob::InterruptError with no retry, and nothing else reclaims the clone
  # inside the reversible window — StaleCloneCleanupJob's archived scopes require
  # `trash_after` to be nil and this session has one, and EmptyTrashJob waits for
  # the deadline. Dropping the run leaves the tree, its Docker resources and its
  # transcript directory on the durable volume for the full retention period.
  #
  # Driven through GoodJob's own mechanism rather than by injecting the exception:
  # `GoodJob::ActiveJobExtensions::InterruptErrors` raises from an `around_perform`
  # when `CurrentThread.execution_interrupted` is set, BEFORE the body runs. It is
  # never raised from inside `perform`, so a test that stubbed a collaborator to
  # raise it would pin a path production cannot take.
  test "a deploy interrupt re-enqueues the cleanup instead of dropping it" do
    interrupt_the_next_execution

    assert_enqueued_with(job: DeferredCloneCleanupJob) do
      DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)
    end

    assert File.directory?(@clone_path), "the clone must survive an interrupted run so the retry can reclaim it"
  end

  test "an unexpected failure re-enqueues the cleanup" do
    GitCloneService.stubs(:cleanup_clone).raises(Errno::EIO, "disk went away")

    assert_enqueued_with(job: DeferredCloneCleanupJob) do
      DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)
    end
  end

  test "the retry carries the same arguments, so it reclaims the same session" do
    interrupt_the_next_execution

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert_enqueued_with(job: DeferredCloneCleanupJob, args: [ @session.id, @archived_at.iso8601 ])
  end

  # The retry makes this reachable, and it is the expensive way to get it wrong:
  # a first run preserves artifacts and deletes the clone, then fails on the way
  # out; the retry finds no clone on disk and takes the "nothing left to hold the
  # deadline open for" branch. `durable_session_storage_exists?` knows about
  # scratch, the Claude config dir and the attachment trees — not about the
  # preserved bundle and patch — so clearing `trash_after` there hands the row to
  # StaleCloneCleanupJob, which deletes the only copy of the session's unpushed
  # work three days early.
  # Stubbed rather than written to disk: the artifacts path is keyed by session id
  # under the shared ~/.zimmer volume, and the fixture id is the same in every
  # parallel test worker — a real directory here is visible to the other workers'
  # copies of this test.
  test "a retry after artifacts were preserved does not clear the trash deadline" do
    CloneArtifactService.any_instance.stubs(:artifacts_exist?).returns(true)
    FileUtils.rm_rf(@clone_path) # the previous attempt already deleted it

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    @session.reload
    assert_not_nil @session.trash_after,
      "preserved artifacts must hold the trash deadline open, or StaleCloneCleanupJob reaps them within the hour"
    assert_in_delta @archived_at + SessionStateMachine::TRASH_RETENTION_PERIOD, @session.trash_after, 5
  end

  test "a clean session with no artifacts and nothing durable still clears the trash deadline" do
    CloneArtifactService.any_instance.stubs(:artifacts_exist?).returns(false)

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert_nil @session.reload.trash_after
  end

  # ActiveSupport resolves rescue handlers last-registered-wins, so the broad
  # `rescue_from(StandardError)` this job registers would otherwise swallow
  # `ApplicationJob`'s `retry_on ActiveRecord::StatementTimeout` — and
  # `DatabaseRetry`, which this job calls through on every write, leaves
  # `QueryAborted` to that inherited handler on purpose. The failure is silent, so
  # it is pinned here rather than left to a comment. Same guard as
  # BundleInstallJob's.
  test "a database timeout still reaches retry_on, not the flat retry ladder" do
    handlers = DeferredCloneCleanupJob.rescue_handlers.map(&:first)

    assert_includes handlers, "StandardError", "the bounded quiet retry is registered"
    assert_equal "ActiveRecord::StatementTimeout", handlers.last,
      "retry_on ActiveRecord::StatementTimeout must be re-registered AFTER rescue_from(StandardError), " \
      "or a database timeout silently takes this job's flat 30s ladder instead of the exponential one"
  end

  test "retries are bounded: the last attempt stops re-enqueueing" do
    interrupt_the_next_execution

    job = DeferredCloneCleanupJob.new(@session.id, @archived_at.iso8601)
    # `perform_now` increments `executions` before performing, so this run is the
    # MAX_ATTEMPTS-th and must not queue another.
    job.executions = DeferredCloneCleanupJob::MAX_ATTEMPTS - 1

    assert_no_enqueued_jobs(only: DeferredCloneCleanupJob) do
      job.perform_now
    end
  end

  # The retry loop must not turn a routine deploy into a page: the "any Zimmer
  # ERROR → critical" rule reads the log level, so an intermediate attempt has to
  # stay at or below WARN and only exhaustion may be loud.
  #
  # The expectation is set on `Rails.logger`, which `ActiveJob::Base.logger` is
  # the same object as here — so it also covers `ActiveJob::LogSubscriber`, whose
  # "Error performing …" / "Discarded …" lines are the class of ERROR the
  # `rescue_from`-over-`retry_on` design exists to avoid.
  test "an intermediate attempt never logs at ERROR" do
    interrupt_the_next_execution

    Rails.logger.expects(:error).never
    # Usually the same object, but expect on both rather than asserting that:
    # a deployment that ever splits them would silently narrow this test instead
    # of failing it.
    ActiveJob::Base.logger.expects(:error).never unless ActiveJob::Base.logger.equal?(Rails.logger)

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)
  end

  test "exhausting the retries logs at ERROR so it stays alertable" do
    interrupt_the_next_execution

    job = DeferredCloneCleanupJob.new(@session.id, @archived_at.iso8601)
    job.executions = DeferredCloneCleanupJob::MAX_ATTEMPTS - 1

    logged = []
    Rails.logger.stubs(:error).with { |*args| logged << args.join(" "); true }

    job.perform_now

    assert logged.any? { |message| message.include?("gave up after") },
      "the last attempt must say so at ERROR; got: #{logged.inspect}"
    assert logged.any? { |message| message.include?(@session.id.to_s) },
      "and must name the session whose clone is left behind"
  end

  private

  # Run `block` against a logger that keeps what it was told, so a test can
  # assert on the LEVEL a line was written at. The level is the whole point here:
  # the "any Zimmer ERROR → critical" Grafana rule reads it, so "retried quietly"
  # and "gave up loudly" are the two behaviours under test.
  # Put GoodJob's interrupt flag up for the next execution, the way a worker that
  # re-picks a row whose `performed_at` is already set does.
  def interrupt_the_next_execution
    GoodJob::CurrentThread.execution_interrupted = 1.minute.ago
  end

  # Drive the job down its "clone is dirty, artifact creation failed" branch.
  def stub_failed_artifact_preservation
    dirty_result = CloneArtifactService::DirtyCheckResult.new(
      dirty?: true,
      has_uncommitted?: true,
      has_unpushed_commits?: false,
      details: "uncommitted changes"
    )
    create_result = CloneArtifactService::CreateResult.new(success?: false, error: "Disk full")

    artifact_service = mock("artifact_service")
    artifact_service.expects(:check_dirty_state).with(@clone_path).returns(dirty_result)
    artifact_service.expects(:create_artifacts)
      .with(session_id: @session.id, clone_path: @clone_path).returns(create_result)
    CloneArtifactService.expects(:new).returns(artifact_service)
  end

  # Drive the job down its "clone is dirty, artifacts preserved" branch with a
  # canned CreateResult, so a test can vary only what the mass-deletion guard
  # reported.
  def stub_artifact_preservation(dropped_deletions:)
    dirty_result = CloneArtifactService::DirtyCheckResult.new(
      dirty?: true,
      has_uncommitted?: true,
      has_unpushed_commits?: false,
      details: "uncommitted changes"
    )
    create_result = CloneArtifactService::CreateResult.new(
      success?: true,
      artifacts_path: "/tmp/artifacts",
      dropped_deletions: dropped_deletions
    )

    artifact_service = mock("artifact_service")
    artifact_service.expects(:check_dirty_state).with(@clone_path).returns(dirty_result)
    artifact_service.expects(:create_artifacts)
      .with(session_id: @session.id, clone_path: @clone_path).returns(create_result)
    CloneArtifactService.expects(:new).returns(artifact_service)
  end
end
