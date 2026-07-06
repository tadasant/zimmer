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
    FileUtils.rm_rf(@test_dir) if @test_dir && File.directory?(@test_dir)
    TranscriptArchiveJob.any_instance.unstub(:archive_dir)
    TranscriptArchiveJob.any_instance.unstub(:archive_path)
    TranscriptArchiveJob.any_instance.unstub(:metadata_path)
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
end
