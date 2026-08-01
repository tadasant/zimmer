# frozen_string_literal: true

require "test_helper"

class TranscriptFileLocatorTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @mock_file_system = MockFileSystemAdapter.new
  end

  test "find_main_transcript returns session_id file when present" do
    @session.update!(session_id: "abc123-def456")

    transcript_dir = "/transcript/dir"
    session_file = "#{transcript_dir}/abc123-def456.jsonl"
    agent_file = "#{transcript_dir}/agent-xyz789.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(session_file, '{"type":"user"}')
    @mock_file_system.write(agent_file, '{"type":"user"}')

    # Make agent file more recent
    @mock_file_system.set_mtime(session_file, 1.hour.ago)
    @mock_file_system.set_mtime(agent_file, Time.current)

    result = TranscriptFileLocator.find_main_transcript(@session, transcript_dir, file_system: @mock_file_system)

    assert_equal session_file, result
  end

  test "find_main_transcript excludes agent files in fallback" do
    @session.update!(session_id: nil)

    transcript_dir = "/transcript/dir"
    main_file = "#{transcript_dir}/some-uuid.jsonl"
    agent_file1 = "#{transcript_dir}/agent-abc.jsonl"
    agent_file2 = "#{transcript_dir}/agent-xyz.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(main_file, '{"type":"user"}')
    @mock_file_system.write(agent_file1, '{"type":"user"}')
    @mock_file_system.write(agent_file2, '{"type":"user"}')

    # Make agent files more recent; all are written after the session started,
    # so only the agent- prefix distinguishes them
    @mock_file_system.set_mtime(main_file, @session.created_at + 1.minute)
    @mock_file_system.set_mtime(agent_file1, @session.created_at + 2.minutes)
    @mock_file_system.set_mtime(agent_file2, @session.created_at + 3.minutes)

    result = TranscriptFileLocator.find_main_transcript(@session, transcript_dir, file_system: @mock_file_system)

    assert_equal main_file, result
  end

  test "find_main_transcript returns nil when only agent files exist" do
    @session.update!(session_id: nil)

    transcript_dir = "/transcript/dir"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write("#{transcript_dir}/agent-abc.jsonl", '{"type":"user"}')
    @mock_file_system.write("#{transcript_dir}/agent-xyz.jsonl", '{"type":"user"}')

    result = TranscriptFileLocator.find_main_transcript(@session, transcript_dir, file_system: @mock_file_system)

    assert_nil result
  end

  test "find_main_transcript returns nil when directory is empty" do
    @session.update!(session_id: nil)

    transcript_dir = "/transcript/dir"
    @mock_file_system.mkdir_p(transcript_dir)

    result = TranscriptFileLocator.find_main_transcript(@session, transcript_dir, file_system: @mock_file_system)

    assert_nil result
  end

  test "find_main_transcript falls back when session_id file not found" do
    @session.update!(session_id: "nonexistent-id")

    transcript_dir = "/transcript/dir"
    main_file = "#{transcript_dir}/actual-file.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(main_file, '{"type":"user"}')

    result = TranscriptFileLocator.find_main_transcript(@session, transcript_dir, file_system: @mock_file_system)

    assert_equal main_file, result
  end

  test "find_main_transcript selects most recent non-agent file in fallback" do
    @session.update!(session_id: nil)

    transcript_dir = "/transcript/dir"
    old_file = "#{transcript_dir}/old-session.jsonl"
    new_file = "#{transcript_dir}/new-session.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(old_file, '{"type":"user"}')
    @mock_file_system.write(new_file, '{"type":"user"}')

    @mock_file_system.set_mtime(old_file, @session.created_at + 1.minute)
    @mock_file_system.set_mtime(new_file, @session.created_at + 2.minutes)

    result = TranscriptFileLocator.find_main_transcript(@session, transcript_dir, file_system: @mock_file_system)

    assert_equal new_file, result
  end

  # === The blank-session_id fallback (#57) ===
  #
  # The fallback exists only for the window between spawning the CLI and
  # capturing the session id it mints. It must not reach outside that window.

  test "find_main_transcript ignores a transcript written before the session started" do
    @session.update!(session_id: nil)

    transcript_dir = "/transcript/dir"
    stale_file = "#{transcript_dir}/previous-occupant.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(stale_file, '{"type":"user"}')
    @mock_file_system.set_mtime(stale_file, @session.created_at - 1.minute)

    result = TranscriptFileLocator.find_main_transcript(@session, transcript_dir, file_system: @mock_file_system)

    assert_nil result,
      "a transcript last written before this session existed belongs to a previous occupant of the working directory"
  end

  test "find_main_transcript still selects a transcript written after the session started" do
    @session.update!(session_id: nil)

    transcript_dir = "/transcript/dir"
    stale_file = "#{transcript_dir}/previous-occupant.jsonl"
    own_file = "#{transcript_dir}/this-session.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(stale_file, '{"type":"user"}')
    @mock_file_system.write(own_file, '{"type":"user"}')

    # The stale file is the newer of the two by mtime alone would be wrong;
    # here it is older than the session, so it is not a candidate at all.
    @mock_file_system.set_mtime(stale_file, @session.created_at - 1.hour)
    @mock_file_system.set_mtime(own_file, @session.created_at + 1.minute)

    result = TranscriptFileLocator.find_main_transcript(@session, transcript_dir, file_system: @mock_file_system)

    assert_equal own_file, result
  end

  test "find_main_transcript prefers the session_id file even when it predates the session" do
    # The floor applies to the fallback only — an exact session_id match is
    # never in doubt, and the restore path (resume_transcript_path) writes that
    # file with whatever mtime the restore happens to produce.
    @session.update!(session_id: "abc123-def456")

    transcript_dir = "/transcript/dir"
    session_file = "#{transcript_dir}/abc123-def456.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(session_file, '{"type":"user"}')
    @mock_file_system.set_mtime(session_file, @session.created_at - 1.hour)

    result = TranscriptFileLocator.find_main_transcript(@session, transcript_dir, file_system: @mock_file_system)

    assert_equal session_file, result
  end

  test "DefaultFileSystem works with real filesystem" do
    # Test that the default file system adapter uses real File operations
    fs = TranscriptFileLocator::DefaultFileSystem.new

    # Test exists? with a file that definitely exists
    assert fs.exists?(__FILE__)

    # Test exists? with a file that doesn't exist
    refute fs.exists?("/nonexistent/path/to/file.txt")

    # Test glob returns array
    result = fs.glob(File.join(File.dirname(__FILE__), "*.rb"))
    assert result.is_a?(Array)
    assert result.any?

    # Test mtime returns Time
    mtime = fs.mtime(__FILE__)
    assert mtime.is_a?(Time)
  end
end
