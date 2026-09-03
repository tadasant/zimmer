# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "zip"

class TranscriptArchiveJobTest < ActiveJob::TestCase
  setup do
    # Use a unique temp directory per test to avoid parallel test interference
    @test_dir = Dir.mktmpdir("transcript_archive_job_test")
    @archive_dir = Pathname.new(@test_dir)
    @archive_path = @archive_dir.join("latest.zip")
    @metadata_path = @archive_dir.join("latest_metadata.json")

    # Stub the job's path methods to use our isolated temp directory
    TranscriptArchiveJob.any_instance.stubs(:archive_dir).returns(@archive_dir)
    TranscriptArchiveJob.any_instance.stubs(:archive_path).returns(@archive_path)
    TranscriptArchiveJob.any_instance.stubs(:metadata_path).returns(@metadata_path)
  end

  teardown do
    ENV.delete("AGENT_TRANSCRIPT_ARCHIVE_DIR")
    FileUtils.rm_rf(@test_dir) if @test_dir && File.directory?(@test_dir)
    TranscriptArchiveJob.any_instance.unstub(:archive_dir)
    TranscriptArchiveJob.any_instance.unstub(:archive_path)
    TranscriptArchiveJob.any_instance.unstub(:metadata_path)
  end

  # Where the archive lives is the whole of #714: the writer runs in the `worker`
  # container and every reader is an HTTP route in `web`, so a path on the container
  # layer means the reader can never see what the writer wrote.
  test "resolves under the shared ~/.zimmer volume, not the container-local storage dir" do
    TranscriptArchiveJob.any_instance.unstub(:archive_dir)
    ENV.delete("AGENT_TRANSCRIPT_ARCHIVE_DIR")

    resolved = TranscriptArchiveJob.archive_dir.to_s

    assert_equal File.join(File.dirname(ClonesDirectory.base), "transcript_archives"), resolved,
      "the archive has to sit on the volume both roles mount, beside the clones"
    assert_not_includes resolved, Rails.root.join("storage").to_s,
      "Rails.root/storage is a per-container overlay layer that no deploy config mounts"
  end

  test "an explicit override wins over the default resolution" do
    TranscriptArchiveJob.any_instance.unstub(:archive_path)
    ENV["AGENT_TRANSCRIPT_ARCHIVE_DIR"] = "/tmp/somewhere-else"

    assert_equal "/tmp/somewhere-else/latest.zip", TranscriptArchiveJob.archive_path.to_s
    assert_equal "/tmp/somewhere-else/latest_metadata.json", TranscriptArchiveJob.metadata_path.to_s
  ensure
    ENV.delete("AGENT_TRANSCRIPT_ARCHIVE_DIR")
  end

  test "creates archive directory if it does not exist" do
    FileUtils.rm_rf(@test_dir)

    TranscriptArchiveJob.perform_now

    assert File.directory?(@test_dir), "Archive directory should be created"
  end

  test "creates zip file with sessions that have transcripts" do
    session = sessions(:archived)
    assert session.transcript.present?, "Fixture should have a transcript"

    TranscriptArchiveJob.perform_now

    assert File.exist?(@archive_path), "Archive zip should be created"

    Zip::File.open(@archive_path) do |zip|
      entry = zip.find_entry("sessions/#{session.id}.json")
      assert_not_nil entry, "Session should be in the zip"

      data = JSON.parse(entry.get_input_stream.read)
      assert_equal session.id, data["id"]
      assert_nil data["title"] # Fixture has no title
      assert_equal session.status, data["status"]
      assert_equal session.prompt, data["prompt"]
      assert_equal session.git_root, data["git_root"]
      assert_equal session.branch, data["branch"]
      assert_equal session.mcp_servers, data["mcp_servers"]
      assert_not_nil data["transcript"]
    end
  end

  test "includes manifest.json in zip" do
    TranscriptArchiveJob.perform_now

    assert File.exist?(@archive_path), "Archive zip should be created"

    Zip::File.open(@archive_path) do |zip|
      manifest_entry = zip.find_entry("manifest.json")
      assert_not_nil manifest_entry, "Manifest should be in the zip"

      manifest = JSON.parse(manifest_entry.get_input_stream.read)
      assert manifest.key?("session_count")
      assert manifest.key?("generated_at")
      assert manifest.key?("session_ids")
      assert manifest["session_ids"].is_a?(Array)
    end
  end

  test "creates metadata file" do
    TranscriptArchiveJob.perform_now

    assert File.exist?(@metadata_path), "Metadata file should be created"

    metadata = JSON.parse(File.read(@metadata_path))
    assert metadata.key?("generated_at")
    assert metadata.key?("session_count")
    assert metadata.key?("file_size_bytes")
    assert metadata.key?("sessions")
    assert metadata["sessions"].is_a?(Hash)
    assert metadata["file_size_bytes"] > 0
  end

  test "skips sessions without transcripts" do
    session_without_transcript = sessions(:running)
    assert_nil session_without_transcript.transcript, "Fixture should not have a transcript"

    TranscriptArchiveJob.perform_now

    assert File.exist?(@archive_path), "Archive zip should be created"

    Zip::File.open(@archive_path) do |zip|
      entry = zip.find_entry("sessions/#{session_without_transcript.id}.json")
      assert_nil entry, "Session without transcript should not be in the zip"
    end
  end

  test "change detection scans transcript markers without loading transcript payloads" do
    relation = TranscriptArchiveJob.new.send(:transcript_session_markers)

    assert_equal [ "id", "updated_at" ], relation.select_values.map(&:to_s)
    assert_match(/"sessions"."transcript" IS NOT NULL/, relation.to_sql)
    assert_no_match(/SELECT "sessions".\*/, relation.to_sql)
  end

  test "incremental update adds new sessions without full rebuild" do
    # First run — creates archive
    TranscriptArchiveJob.perform_now
    first_metadata = JSON.parse(File.read(@metadata_path))
    first_session_count = first_metadata["session_count"]

    # Add transcript to a session that previously had none
    session = sessions(:running)
    session.update!(transcript: '{"type": "user", "message": {"role": "user", "content": "new transcript"}, "timestamp": "2025-01-01T00:00:00Z"}')

    # Second run — should be incremental
    TranscriptArchiveJob.perform_now
    second_metadata = JSON.parse(File.read(@metadata_path))

    assert_equal first_session_count + 1, second_metadata["session_count"],
      "Session count should increase by 1"

    Zip::File.open(@archive_path) do |zip|
      entry = zip.find_entry("sessions/#{session.id}.json")
      assert_not_nil entry, "Newly transcripted session should be in the zip"
    end
  end

  test "incremental update refreshes changed sessions" do
    # First run
    session = sessions(:archived)
    TranscriptArchiveJob.perform_now

    original_transcript = session.transcript

    # Update session transcript
    session.update!(transcript: original_transcript + "\n" + '{"type": "user", "message": {"role": "user", "content": "follow up"}, "timestamp": "2025-12-01T00:00:00Z"}')

    # Second run
    TranscriptArchiveJob.perform_now

    Zip::File.open(@archive_path) do |zip|
      entry = zip.find_entry("sessions/#{session.id}.json")
      assert_not_nil entry
      data = JSON.parse(entry.get_input_stream.read)
      assert_includes data["transcript"], "follow up", "Updated transcript should be in the zip"
    end
  end

  test "skips rebuild when no changes detected" do
    TranscriptArchiveJob.perform_now
    first_metadata = JSON.parse(File.read(@metadata_path))
    first_generated_at = first_metadata["generated_at"]

    # Sleep briefly to ensure timestamp would differ
    sleep 0.1

    TranscriptArchiveJob.perform_now
    second_metadata = JSON.parse(File.read(@metadata_path))

    assert_equal first_generated_at, second_metadata["generated_at"],
      "Metadata should not be updated when no changes detected"
  end

  test "metadata scan does not load transcript payloads before detecting changes" do
    session = sessions(:archived)
    assert session.transcript.present?, "Fixture should have a transcript"

    session_selects = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].squish
      next unless sql.match?(/\ASELECT .* FROM "sessions"/)

      session_selects << sql
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      TranscriptArchiveJob.perform_now
    end

    metadata_scan = session_selects.find do |sql|
      sql.include?("\"sessions\".\"transcript\" IS NOT NULL") &&
        sql.include?("ORDER BY \"sessions\".\"id\" ASC") &&
        sql.include?("LIMIT")
    end

    assert_not_nil metadata_scan, "Expected TranscriptArchiveJob to scan transcript-bearing sessions in id order"
    select_list = metadata_scan[/\ASELECT (.+?) FROM "sessions"/, 1]
    assert_includes select_list, "\"sessions\".\"id\""
    assert_includes select_list, "\"sessions\".\"updated_at\""
    assert_not_includes metadata_scan, "\"sessions\".*"
    assert_not_includes select_list, "\"sessions\".\"transcript\""
  end

  test "includes subagent transcripts in zip" do
    session = sessions(:archived)

    # Create a subagent transcript for the session
    subagent = SubagentTranscript.create!(
      session: session,
      agent_id: "test-agent-123",
      transcript: '{"type": "user", "message": {"role": "user", "content": "subagent task"}}',
      status: "completed"
    )

    TranscriptArchiveJob.perform_now

    Zip::File.open(@archive_path) do |zip|
      entry = zip.find_entry("sessions/#{session.id}/subagent_transcripts/#{subagent.agent_id}.json")
      assert_not_nil entry, "Subagent transcript should be in the zip"

      data = JSON.parse(entry.get_input_stream.read)
      assert_equal "test-agent-123", data["agent_id"]
      assert_equal session.id, data["session_id"]
      assert_equal "completed", data["status"]
    end
  ensure
    subagent&.destroy
  end

  test "handles corrupt metadata file gracefully" do
    File.write(@metadata_path, "not valid json{{{")

    assert_nothing_raised do
      TranscriptArchiveJob.perform_now
    end

    assert File.exist?(@archive_path), "Archive should still be created"
  end

  test "writes atomically via temp file" do
    # After the job runs, no temp files should remain
    TranscriptArchiveJob.perform_now

    temp_files = Dir.glob(@archive_dir.join("latest_*.zip.tmp"))
    assert_empty temp_files, "No temp files should remain after job completes"
  end

  test "manifest session_count matches metadata session_count" do
    TranscriptArchiveJob.perform_now

    metadata = JSON.parse(File.read(@metadata_path))

    Zip::File.open(@archive_path) do |zip|
      manifest = JSON.parse(zip.find_entry("manifest.json").get_input_stream.read)
      assert_equal metadata["session_count"], manifest["session_count"],
        "Manifest and metadata session counts should match"
    end
  end

  # ---------------------------------------------------------------------------
  # #719 — the job's peak memory is decided by how many transcripts it holds at
  # once. The build used to be handed `Session.where(id: […]).to_a`, which held
  # every changed session live for the whole build; on a corpus that had never
  # been archived that is every session in the database. On production it took the
  # worker cgroup from a 1.5–2.5 GiB baseline to its 10 GiB cap in about ninety
  # seconds, roughly four times an hour, with a single job thread active.
  # ---------------------------------------------------------------------------

  # Full-row reads are the ones that carry `transcript`. The marker scan selects only
  # id and updated_at and is pinned by its own test above.
  def full_session_row_selects(&block)
    selects = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].squish
      selects << sql if sql.match?(/\ASELECT "sessions"\.\* FROM "sessions"/)
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    selects
  end

  test "loads transcript payloads one session at a time, never as a batch" do
    selects = full_session_row_selects { TranscriptArchiveJob.perform_now }

    assert_not_empty selects, "expected the job to load session payloads at all"

    selects.each do |sql|
      assert_match(/WHERE "sessions"\."id" = /, sql,
        "every transcript-bearing read must fetch a single session: #{sql}")
      assert_no_match(/"sessions"\."id" IN /, sql,
        "a multi-id payload read is exactly the #719 allocation: #{sql}")
    end
  end

  test "reads one full session row per session it archives, and no more" do
    selects = full_session_row_selects { TranscriptArchiveJob.perform_now }

    archived = JSON.parse(File.read(@metadata_path))["sessions"].size

    assert_equal archived, selects.size,
      "the job should not instantiate sessions it does not write into the zip"
  end

  test "reconciling subagent-bearing sessions reads only the ones it rebuilds" do
    # Two sessions with NO main transcript, so the marker scan never sees them and both
    # are live reconciliation candidates on every run. One of them then changes; the other
    # has to be settled without loading its transcript payload — the per-candidate
    # `Session.find_by` this replaced loaded both in full, transcript column and all, just
    # to ask whether the rows were still there.
    changed = SubagentTranscript.create!(
      session: sessions(:running),
      agent_id: "reconcile-#{SecureRandom.hex(4)}",
      transcript: '{"type": "user", "message": {"role": "user", "content": "hi"}}',
      status: "completed"
    )
    untouched = SubagentTranscript.create!(
      session: sessions(:waiting),
      agent_id: "reconcile-#{SecureRandom.hex(4)}",
      transcript: '{"type": "user", "message": {"role": "user", "content": "hi"}}',
      status: "completed"
    )

    # A first run archives everything, so the second run's only session work is the
    # subagent reconciliation pass.
    TranscriptArchiveJob.perform_now

    changed.update!(transcript: '{"type": "user", "message": {"role": "user", "content": "more"}}')

    selects = full_session_row_selects { TranscriptArchiveJob.perform_now }

    assert_equal 1, selects.size,
      "only the session whose subagent transcript moved should be loaded: #{selects.inspect}"
  ensure
    changed&.destroy
    untouched&.destroy
  end

  # The pass exists for sessions the marker scan cannot reach at all. Nothing else in the
  # suite gives a subagent transcript to a session with `transcript: nil`, so without this
  # the queueing half of the reconciliation pass is never executed — and the narrowing
  # this change makes there (such a session used to be rebuilt on every single run) would
  # be free to become "never archived at all" without a single test failing.
  test "a session with subagent transcripts and no main transcript is archived, then settles" do
    session = sessions(:running)
    assert_nil session.transcript, "this test needs a session the marker scan will not see"

    agent_id = "no-main-#{SecureRandom.hex(4)}"
    subagent = SubagentTranscript.create!(
      session: session,
      agent_id: agent_id,
      transcript: '{"type": "user", "message": {"role": "user", "content": "only a subagent"}}',
      status: "completed"
    )

    TranscriptArchiveJob.perform_now

    Zip::File.open(@archive_path) do |zip|
      assert_not_nil zip.find_entry("sessions/#{session.id}/subagent_transcripts/#{agent_id}.json"),
        "a session reachable only through the reconciliation pass still has to be archived"
    end
    assert_includes JSON.parse(File.read(@metadata_path))["sessions"].keys, session.id.to_s

    selects = full_session_row_selects { TranscriptArchiveJob.perform_now }

    assert_empty selects,
      "and then settle — it used to be rebuilt on every single run"

    Zip::File.open(@archive_path) do |zip|
      assert_not_nil zip.find_entry("sessions/#{session.id}/subagent_transcripts/#{agent_id}.json"),
        "a settled entry is carried forward from the old zip, not rewritten from the DB"
    end
  ensure
    subagent&.destroy
  end

  # What makes shipping this cost one re-archive per subagent-bearing session rather than a
  # full corpus rebuild: for the sessions that have none — most of them — the recorded stamp
  # is `sessions.updated_at` byte-for-byte, so an existing sidecar goes on matching. A stamp
  # rendered any other way (`.utc`, second precision) would silently re-archive everything on
  # the deploy that introduced it.
  test "a session with no subagent transcripts is stamped exactly as before" do
    TranscriptArchiveJob.perform_now

    session = sessions(:with_transcript)
    assert_empty session.subagent_transcripts, "this test needs a session with no subagent transcripts"

    recorded = JSON.parse(File.read(@metadata_path))["sessions"][session.id.to_s]
    assert_equal session.reload.updated_at.iso8601(6), recorded
  end

  # ---------------------------------------------------------------------------
  # #720 — a session's zip entry carries its subagent transcripts, but change
  # detection only ever compared `sessions.updated_at`, and `SubagentTranscript` has no
  # `touch:` on its parent. A subagent transcript written after its session's last
  # archive was invisible to both passes: the main scan saw an unchanged `updated_at`,
  # and the reconciliation pass skipped any session already present in the metadata. The
  # run took its "No changes detected" early return and the transcript stayed out of
  # latest.zip until some unrelated write happened to bump the session row.
  # ---------------------------------------------------------------------------

  test "a subagent transcript created after a session's last archive reaches the next zip" do
    session = sessions(:archived)
    TranscriptArchiveJob.perform_now
    assert File.exist?(@archive_path), "the first run has to publish an archive to add to"

    agent_id = "post-archive-#{SecureRandom.hex(4)}"
    subagent = SubagentTranscript.create!(
      session: session,
      agent_id: agent_id,
      transcript: '{"type": "user", "message": {"role": "user", "content": "written after the archive"}}',
      status: "completed"
    )

    Rails.logger.stubs(:info)
    Rails.logger.expects(:info).with(regexp_matches(/No changes detected/)).never

    TranscriptArchiveJob.perform_now

    Zip::File.open(@archive_path) do |zip|
      entry = zip.find_entry("sessions/#{session.id}/subagent_transcripts/#{agent_id}.json")
      assert_not_nil entry,
        "a subagent transcript written after the last archive has to reach latest.zip"
      assert_includes JSON.parse(entry.get_input_stream.read)["transcript"], "written after the archive"
    end
  ensure
    subagent&.destroy
  end

  test "a subagent transcript that grows after its session's last archive is re-archived" do
    session = sessions(:archived)
    agent_id = "growing-#{SecureRandom.hex(4)}"
    subagent = SubagentTranscript.create!(
      session: session,
      agent_id: agent_id,
      transcript: '{"type": "user", "message": {"role": "user", "content": "first"}}',
      status: "running"
    )

    TranscriptArchiveJob.perform_now

    subagent.update!(
      transcript: '{"type": "user", "message": {"role": "user", "content": "second"}}',
      status: "completed"
    )

    Rails.logger.stubs(:info)
    Rails.logger.expects(:info).with(regexp_matches(/No changes detected/)).never

    TranscriptArchiveJob.perform_now

    Zip::File.open(@archive_path) do |zip|
      data = JSON.parse(zip.find_entry("sessions/#{session.id}/subagent_transcripts/#{agent_id}.json")
        .get_input_stream.read)
      assert_includes data["transcript"], "second",
        "the archive should carry the subagent transcript as it stands now"
      assert_equal "completed", data["status"]
    end
  ensure
    subagent&.destroy
  end

  # The other half of the stamp: it has to settle. A session whose subagent transcripts
  # have not moved since its last archive must not be rebuilt on every tick — that is the
  # over-broad failure mode, and it is silent in a job already bounded by memory.
  test "a session whose subagent transcripts have not moved is not rebuilt again" do
    subagent = SubagentTranscript.create!(
      session: sessions(:archived),
      agent_id: "settled-#{SecureRandom.hex(4)}",
      transcript: '{"type": "user", "message": {"role": "user", "content": "hi"}}',
      status: "completed"
    )

    TranscriptArchiveJob.perform_now

    selects = full_session_row_selects { TranscriptArchiveJob.perform_now }

    assert_empty selects,
      "nothing changed, so the run should reach its no-op early return rather than rebuild"
  ensure
    subagent&.destroy
  end

  test "caps how many sessions one run archives and defers the rest" do
    total = Session.where.not(transcript: nil).count
    assert_operator total, :>, 1, "fixtures need more than one transcript to exercise the cap"

    TranscriptArchiveJob.any_instance.stubs(:max_sessions_per_run).returns(1)

    TranscriptArchiveJob.perform_now

    metadata = JSON.parse(File.read(@metadata_path))
    assert_equal 1, metadata["sessions"].size, "a capped run should archive exactly its slice"
    assert File.exist?(@archive_path), "a capped run still has to publish what it did"
  end

  # The convergence half. A run that defers has to record the slice it finished, or the
  # next tick starts from zero and stops in the same place — which is #495, and is why
  # production had never completed a single run.
  test "a capped run checkpoints its progress so the next run resumes after it" do
    total = Session.where.not(transcript: nil).count
    assert_operator total, :>, 1, "fixtures need more than one transcript to exercise this"

    TranscriptArchiveJob.any_instance.stubs(:max_sessions_per_run).returns(1)

    counts = Array.new(total) do
      TranscriptArchiveJob.perform_now
      JSON.parse(File.read(@metadata_path))["sessions"].size
    end

    assert_equal (1..total).to_a, counts,
      "each run should add exactly one more session rather than restarting the corpus"

    Zip::File.open(@archive_path) do |zip|
      Session.where.not(transcript: nil).pluck(:id).each do |id|
        assert_not_nil zip.find_entry("sessions/#{id}.json"),
          "session #{id} should have been picked up by one of the #{total} runs"
      end
    end
  end

  # Production ships only WARN and above to VictoriaLogs, so an INFO line here would be
  # invisible on the one deployment that needs it. This is the line that names the job
  # while it is catching up.
  test "warns when a run defers work, at the severity production actually ships" do
    TranscriptArchiveJob.any_instance.stubs(:max_sessions_per_run).returns(1)

    Rails.logger.stubs(:warn)
    Rails.logger.expects(:warn).with(regexp_matches(/\[TranscriptArchiveJob\].*deferred to the next tick/)).at_least_once

    TranscriptArchiveJob.perform_now
  end

  test "does not warn when the whole backlog fits in one run" do
    Rails.logger.stubs(:warn)
    Rails.logger.expects(:warn).with(regexp_matches(/deferred to the next tick/)).never

    TranscriptArchiveJob.perform_now
  end

  # ---------------------------------------------------------------------------
  # Findings from the fresh-eyes review of #721.
  # ---------------------------------------------------------------------------

  # The sidecar describes a zip. If the zip is gone and the sidecar is not, every session
  # it lists is recorded as archived into a file that does not exist — and since those
  # sessions are not "changed" and there is no old archive to copy them from, they would
  # never be rebuilt while manifest.json went on reporting the full count.
  test "a surviving sidecar is discarded when the zip it describes is gone" do
    TranscriptArchiveJob.perform_now
    archived_ids = JSON.parse(File.read(@metadata_path))["sessions"].keys.sort
    assert_operator archived_ids.size, :>, 0

    File.delete(@archive_path)

    TranscriptArchiveJob.perform_now

    assert File.exist?(@archive_path), "the archive should have been rebuilt"
    rebuilt = JSON.parse(File.read(@metadata_path))["sessions"].keys.sort
    assert_equal archived_ids, rebuilt, "metadata should still claim the same sessions"

    Zip::File.open(@archive_path) do |zip|
      archived_ids.each do |id|
        assert_not_nil zip.find_entry("sessions/#{id}.json"),
          "session #{id} is claimed by the sidecar, so it has to be back in the zip"
      end
    end
  end

  # A mid-bootstrap archive is freshly written, so `stale?` is false and nothing else
  # distinguishes it from a complete one. AGENTS.md wants that answerable without a shell.
  test "a deferred run records its backlog in the metadata, not only in the log" do
    TranscriptArchiveJob.any_instance.stubs(:max_sessions_per_run).returns(1)
    total = Session.where.not(transcript: nil).count

    TranscriptArchiveJob.perform_now

    metadata = JSON.parse(File.read(@metadata_path))
    assert_equal total - 1, metadata["deferred_count"]
    assert_equal false, metadata["complete"]

    status = TranscriptArchiveStatus.new(archive_path: @archive_path, metadata_path: @metadata_path)
    assert_not status.complete?
    assert_equal total - 1, status.deferred_count
    assert_not status.stale?, "a just-written partial archive is incomplete, not stale"
    assert_match(/prefix of the corpus/, status.incompleteness_note)
  end

  test "a run that clears its backlog records the archive as complete" do
    TranscriptArchiveJob.perform_now

    metadata = JSON.parse(File.read(@metadata_path))
    assert_equal 0, metadata["deferred_count"]
    assert_equal true, metadata["complete"]

    status = TranscriptArchiveStatus.new(archive_path: @archive_path, metadata_path: @metadata_path)
    assert status.complete?
    assert_nil status.incompleteness_note
  end

  # The trickiest interaction in the change: removals force the full-rebuild path, and the
  # cap truncates the changed set at the same time. A deferred session must be postponed,
  # never dropped.
  test "a deferred session survives a run that also processes a removal" do
    TranscriptArchiveJob.perform_now
    archived_ids = JSON.parse(File.read(@metadata_path))["sessions"].keys.sort
    assert_operator archived_ids.size, :>, 2, "need enough fixtures to defer and remove"

    # Force every remaining session to look changed, then remove one and cap the run.
    Session.where.not(transcript: nil).find_each { |s| s.update_column(:updated_at, 1.hour.from_now) }
    removed = Session.where.not(transcript: nil).order(:id).last
    removed_id = removed.id.to_s
    removed.update_column(:transcript, nil)

    TranscriptArchiveJob.any_instance.stubs(:max_sessions_per_run).returns(1)
    TranscriptArchiveJob.perform_now

    metadata = JSON.parse(File.read(@metadata_path))
    assert_not_includes metadata["sessions"].keys, removed_id,
      "the removed session should be dropped from tracking"

    survivors = archived_ids - [ removed_id ]
    Zip::File.open(@archive_path) do |zip|
      survivors.each do |id|
        assert_not_nil zip.find_entry("sessions/#{id}.json"),
          "session #{id} was deferred, not removed — its entry must survive the rebuild"
      end
    end
    assert_equal survivors.sort, metadata["sessions"].keys.sort
  end

  # The id stays in changed_ids, so it is subtracted out of unchanged_ids and its old entry
  # is not copied forward either. Leaving the claim would have the manifest counting an
  # entry the zip does not contain.
  test "a session deleted mid-run is dropped from metadata rather than left claimed" do
    TranscriptArchiveJob.perform_now

    doomed = Session.where.not(transcript: nil).order(:id).first
    doomed_id = doomed.id.to_s
    doomed.update_column(:updated_at, 1.hour.from_now)

    # The row is gone by the time the build tries to load it — the race between the change
    # scan and each_changed_session. `find_by` is the job's only per-session payload read.
    Session.stubs(:find_by).returns(nil)

    TranscriptArchiveJob.perform_now

    metadata = JSON.parse(File.read(@metadata_path))
    assert_not_includes metadata["sessions"].keys, doomed_id,
      "a row that vanished before it could be loaded must not stay claimed in metadata"

    Zip::File.open(@archive_path) do |zip|
      manifest = JSON.parse(zip.find_entry("manifest.json").get_input_stream.read)
      assert_equal metadata["sessions"].size, manifest["session_count"]
      manifest["session_ids"].each do |id|
        assert_not_nil zip.find_entry("sessions/#{id}.json"),
          "manifest must not count an entry the zip does not contain"
      end
    end
  end
end
