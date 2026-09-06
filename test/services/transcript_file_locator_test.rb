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

  test "find_main_transcript tolerates a coarse filesystem mtime at the floor" do
    # A filesystem storing whole-second mtimes can report a write from the same
    # second as the session's creation as fractionally older than it. That file
    # is this session's own transcript and must still be found.
    @session.update!(session_id: nil)

    transcript_dir = "/transcript/dir"
    own_file = "#{transcript_dir}/this-session.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(own_file, '{"type":"user"}')
    @mock_file_system.set_mtime(own_file, @session.created_at - 0.5.seconds)

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

  # === Following a re-keyed transcript branch (#1047) ===
  #
  # The runtime can copy a live conversation forward into a file named by a NEW
  # session uuid and carry on appending to the copy. Preferring the recorded name
  # there polls a conversation that stopped.

  test "find_main_transcript follows a branch the runtime re-keyed to a new uuid" do
    dirs = build_rekeyed_branch

    result = TranscriptFileLocator.find_main_transcript(@session, dirs[:dir], file_system: @mock_file_system)

    assert_equal dirs[:branch], result,
      "the branch carrying this conversation forward is the one being written"
  end

  test "find_main_transcript keeps the recorded file when nothing re-keyed" do
    transcript_dir = "/transcript/dir"
    @session.update!(session_id: "recorded-uuid")
    recorded = "#{transcript_dir}/recorded-uuid.jsonl"

    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(recorded, transcript_line("recorded-uuid", "only file"))
    @mock_file_system.set_mtime(recorded, Time.current)

    result = TranscriptFileLocator.find_main_transcript(@session, transcript_dir, file_system: @mock_file_system)

    assert_equal recorded, result
  end

  test "find_main_transcript ignores a newer sibling that carries someone else's conversation" do
    dirs = build_rekeyed_branch(branch_head_session_id: "a-previous-occupant")

    result = TranscriptFileLocator.find_main_transcript(@session, dirs[:dir], file_system: @mock_file_system)

    assert_equal dirs[:recorded], result,
      "identity comes from the head sessionId, never from mtime alone"
  end

  test "find_main_transcript never follows a fork's transcript" do
    # A fork's transcript is copied verbatim from its source, so its head carries
    # the SOURCE session's id — the same shape a re-key has. The uuid belonging to
    # another Session row is what tells the two apart.
    fork = sessions(:needs_input)
    fork.update!(session_id: "the-fork-uuid")

    dirs = build_rekeyed_branch(branch_id: "the-fork-uuid")

    result = TranscriptFileLocator.find_main_transcript(@session, dirs[:dir], file_system: @mock_file_system)

    assert_equal dirs[:recorded], result,
      "a fork that ran in this working directory is a different conversation"
  end

  test "find_main_transcript keeps the recorded file when the branch is the older one" do
    dirs = build_rekeyed_branch
    @mock_file_system.set_mtime(dirs[:branch], 2.hours.ago)
    @mock_file_system.set_mtime(dirs[:recorded], Time.current)

    result = TranscriptFileLocator.find_main_transcript(@session, dirs[:dir], file_system: @mock_file_system)

    assert_equal dirs[:recorded], result,
      "a branch has to be more recently written to displace the recorded name"
  end

  test "find_main_transcript breaks an mtime tie in favour of the recorded file" do
    dirs = build_rekeyed_branch
    tie = Time.current
    @mock_file_system.set_mtime(dirs[:branch], tie)
    @mock_file_system.set_mtime(dirs[:recorded], tie)

    result = TranscriptFileLocator.find_main_transcript(@session, dirs[:dir], file_system: @mock_file_system)

    assert_equal dirs[:recorded], result
  end

  test "find_main_transcript ignores an agent transcript that quotes this session's id" do
    dirs = build_rekeyed_branch(branch_id: "agent-abc123")

    result = TranscriptFileLocator.find_main_transcript(@session, dirs[:dir], file_system: @mock_file_system)

    assert_equal dirs[:recorded], result
  end

  test "find_main_transcript follows the branch when the recorded file is gone" do
    dirs = build_rekeyed_branch
    @mock_file_system.rm_rf(dirs[:recorded])

    result = TranscriptFileLocator.find_main_transcript(@session, dirs[:dir], file_system: @mock_file_system)

    assert_equal dirs[:branch], result
  end

  # === rekeyed_branch_id ===

  test "rekeyed_branch_id names the branch a located transcript belongs to" do
    dirs = build_rekeyed_branch

    assert_equal "branch-uuid",
      TranscriptFileLocator.rekeyed_branch_id(@session, dirs[:branch], file_system: @mock_file_system)
  end

  test "rekeyed_branch_id is nil for the recorded transcript" do
    dirs = build_rekeyed_branch

    assert_nil TranscriptFileLocator.rekeyed_branch_id(@session, dirs[:recorded], file_system: @mock_file_system)
  end

  test "rekeyed_branch_id is nil for a file whose head is not this conversation" do
    # The pre-session_id fallback can hand back a file this locator never
    # established an identity for. Calling that a branch would let the poller
    # splice a foreign conversation onto the stored transcript.
    dirs = build_rekeyed_branch(branch_head_session_id: "someone-else")

    assert_nil TranscriptFileLocator.rekeyed_branch_id(@session, dirs[:branch], file_system: @mock_file_system)
  end

  test "rekeyed_branch_id is nil when the session has no recorded id yet" do
    dirs = build_rekeyed_branch
    @session.update!(session_id: nil)

    assert_nil TranscriptFileLocator.rekeyed_branch_id(@session, dirs[:branch], file_system: @mock_file_system)
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

    # Test each_line yields the file's lines
    first = nil
    fs.each_line(__FILE__) { |line| first = line; break }
    assert_equal "# frozen_string_literal: true\n", first
  end

  private

  def transcript_line(session_id, text)
    { "type" => "user", "sessionId" => session_id, "message" => { "role" => "user", "content" => text } }.to_json + "\n"
  end

  # The issue's shape: an abandoned <session_id>.jsonl, and alongside it a file
  # named by a new uuid whose head duplicates the recorded transcript and whose
  # tail is written under that new uuid.
  def build_rekeyed_branch(branch_id: "branch-uuid", branch_head_session_id: "recorded-uuid")
    @session.update!(session_id: "recorded-uuid")

    dir = "/transcript/dir"
    recorded = "#{dir}/recorded-uuid.jsonl"
    branch = "#{dir}/#{branch_id}.jsonl"

    head = (1..3).map { |i| transcript_line("recorded-uuid", "shared #{i}") }.join
    branch_head = (1..3).map { |i| transcript_line(branch_head_session_id, "shared #{i}") }.join
    branch_tail = (1..2).map { |i| transcript_line(branch_id, "after the re-key #{i}") }.join

    @mock_file_system.mkdir_p(dir)
    @mock_file_system.write(recorded, head)
    @mock_file_system.write(branch, branch_head + branch_tail)
    @mock_file_system.set_mtime(recorded, 1.hour.ago)
    @mock_file_system.set_mtime(branch, Time.current)

    { dir: dir, recorded: recorded, branch: branch }
  end
end
