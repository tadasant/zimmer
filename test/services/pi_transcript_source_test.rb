# frozen_string_literal: true

require "test_helper"

class PiTranscriptSourceTest < ActiveSupport::TestCase
  SESSION_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

  setup do
    @dir = Dir.mktmpdir("pi-transcript-source")
    @working_directory = File.join(@dir, "clone")
    @sessions = File.join(@working_directory, ".pi", "sessions")
    FileUtils.mkdir_p(@sessions)
    @source = PiTranscriptSource.new
    @session = build_session(SESSION_ID)
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  test "session_directory is the per-clone .pi/sessions path" do
    assert_equal @sessions, PiTranscriptSource.session_directory(working_directory: @working_directory)
  end

  test "session_directory is nil for a blank working directory" do
    assert_nil PiTranscriptSource.session_directory(working_directory: nil)
    assert_nil PiTranscriptSource.session_directory(working_directory: "")
  end

  test "resume_transcript_path is a deterministic path inside the clone" do
    assert_equal(
      File.join(@sessions, "zimmer_session.jsonl"),
      @source.resume_transcript_path(session: @session, working_directory: @working_directory)
    )
  end

  test "resume_transcript_path is nil before a session id exists" do
    assert_nil @source.resume_transcript_path(session: build_session(nil), working_directory: @working_directory)
  end

  test "locate finds the file Pi named after the session id" do
    path = write_transcript("2026-09-01T10-00-00-000Z_#{SESSION_ID}.jsonl", SESSION_ID)

    assert_equal path, @source.locate(session: @session, working_directory: @working_directory)
  end

  test "locate ignores another session's transcript file" do
    write_transcript("2026-09-01T10-00-00-000Z_11111111-2222-3333-4444-555555555555.jsonl", "other")

    assert_nil @source.locate(session: @session, working_directory: @working_directory)
  end

  test "locate finds a Zimmer-restored transcript whose header carries this session id" do
    path = write_transcript("zimmer_session.jsonl", SESSION_ID)

    assert_equal path, @source.locate(session: @session, working_directory: @working_directory)
  end

  # The restored filename is fixed, so it cannot identify a session on its own. A
  # clone recreated for a DIFFERENT session leaves a file at the same path, and
  # returning it unchecked would show one session another's conversation.
  test "locate refuses a restored transcript whose header carries a different session id" do
    write_transcript("zimmer_session.jsonl", "11111111-2222-3333-4444-555555555555")

    assert_nil @source.locate(session: @session, working_directory: @working_directory)
  end

  test "locate returns nil when the session directory does not exist yet" do
    FileUtils.remove_entry(@sessions)

    assert_nil @source.locate(session: @session, working_directory: @working_directory)
  end

  test "parse_events parses one JSON object per line and drops malformed lines" do
    serialized = <<~JSONL
      {"type":"session","version":3,"id":"#{SESSION_ID}"}
      not json at all
      {"type":"message","id":"a1","parentId":null,"message":{"role":"user","content":"hi"}}
    JSONL

    events = @source.parse_events(serialized)

    assert_equal 2, events.length
    assert_equal %w[session message], events.map { |e| e["type"] }
  end

  test "parse_events returns empty for blank input" do
    assert_equal [], @source.parse_events(nil)
    assert_equal [], @source.parse_events("")
  end

  test "read_raw returns the file contents unchanged" do
    path = write_transcript("zimmer_session.jsonl", SESSION_ID)

    assert_equal File.read(path), @source.read_raw(path)
  end

  # Pi resumes into ONE canonical file via --session-id, so a shorter read means
  # the file was lost, not that a newer file took over.
  test "rotates_transcript_files? is false" do
    assert_not @source.rotates_transcript_files?
  end

  test "Pi has no subagents or per-server MCP logs" do
    assert_equal [], @source.discover_subagent_files(working_directory: @working_directory, session_id: SESSION_ID)
    assert_equal [], @source.mcp_log_paths(working_directory: @working_directory)
  end

  private

  def build_session(session_id)
    Session.new(
      session_id: session_id,
      agent_runtime: "pi",
      metadata: { "working_directory" => @working_directory }
    )
  end

  def write_transcript(filename, header_id)
    path = File.join(@sessions, filename)
    File.write(path, <<~JSONL)
      {"type":"session","version":3,"id":"#{header_id}","timestamp":"2026-09-01T10:00:00.000Z","cwd":"#{@working_directory}"}
      {"type":"message","id":"a1b2c3d4","parentId":null,"timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}
    JSONL
    path
  end
end
