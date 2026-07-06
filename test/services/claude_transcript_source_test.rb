# frozen_string_literal: true

require "test_helper"

class ClaudeTranscriptSourceTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @file_system = MockFileSystemAdapter.new
    @source = ClaudeTranscriptSource.new(file_system: @file_system)
    @working_directory = "/tmp/test-clone"
    @transcript_dir = File.join(File.expand_path("~"), ".claude", "projects", "-tmp-test-clone")
  end

  # === transcript_directory ===

  test "transcript_directory replaces special characters with dashes" do
    result = @source.transcript_directory(working_directory: "/Users/test_user/.hidden/project")

    expected = File.join(File.expand_path("~"), ".claude", "projects", "-Users-test-user--hidden-project")
    assert_equal expected, result
  end

  test "transcript_directory returns nil without a working_directory" do
    assert_nil @source.transcript_directory(working_directory: nil)
  end

  # === locate ===

  test "locate returns nil when the transcript directory does not exist" do
    assert_nil @source.locate(session: @session, working_directory: @working_directory)
  end

  test "locate returns the session_id transcript when present" do
    @session.update!(session_id: "abc123")
    @file_system.mkdir_p(@transcript_dir)
    main_file = "#{@transcript_dir}/abc123.jsonl"
    @file_system.write(main_file, '{"type":"user"}')
    @file_system.write("#{@transcript_dir}/agent-xyz.jsonl", '{"type":"user"}')

    assert_equal main_file, @source.locate(session: @session, working_directory: @working_directory)
  end

  # === resume_transcript_path ===

  test "resume_transcript_path points at <transcript_directory>/<session_id>.jsonl" do
    @session.update!(session_id: "abc123")

    expected = File.join(@transcript_dir, "abc123.jsonl")
    assert_equal expected, @source.resume_transcript_path(session: @session, working_directory: @working_directory)
  end

  test "resume_transcript_path is the exact file locate resumes from, not the CLI cache dir" do
    # Guards the regression that wrote restored transcripts to ~/.cache/claude-cli-nodejs
    # (MCP-log dir) instead of ~/.claude/projects, leaving --resume on a truncated file.
    @session.update!(session_id: "abc123")

    path = @source.resume_transcript_path(session: @session, working_directory: @working_directory)
    assert path.start_with?(File.join(File.expand_path("~"), ".claude", "projects")),
      "resume transcript must live under ~/.claude/projects, got #{path}"
    refute_includes path, "claude-cli-nodejs", "resume transcript must NOT live in the CLI cache directory"

    # The restore target must be the same file `locate` reads on resume.
    @file_system.mkdir_p(File.dirname(path))
    @file_system.write(path, '{"type":"user"}')
    assert_equal path, @source.locate(session: @session, working_directory: @working_directory)
  end

  test "resume_transcript_path returns nil without a session_id" do
    @session.update!(session_id: nil)
    assert_nil @source.resume_transcript_path(session: @session, working_directory: @working_directory)
  end

  test "resume_transcript_path returns nil without a working_directory" do
    @session.update!(session_id: "abc123")
    assert_nil @source.resume_transcript_path(session: @session, working_directory: nil)
  end

  # === read / parse_events / read_events ===

  test "parse_events parses one JSON object per line and drops malformed lines" do
    serialized = "{\"a\":1}\nnot json\n{\"b\":2}\n"

    assert_equal [ { "a" => 1 }, { "b" => 2 } ], @source.parse_events(serialized)
  end

  test "parse_events returns empty array for blank content" do
    assert_equal [], @source.parse_events("")
    assert_equal [], @source.parse_events(nil)
  end

  test "read_events reads the file and parses it" do
    path = "#{@transcript_dir}/abc.jsonl"
    @file_system.write(path, "{\"type\":\"user\"}\n{\"type\":\"assistant\"}\n")

    assert_equal [ { "type" => "user" }, { "type" => "assistant" } ], @source.read_events(path)
  end

  # === discover_subagent_files ===

  test "discover_subagent_files globs agent-*.jsonl in the transcript directory" do
    @file_system.mkdir_p(@transcript_dir)
    @file_system.write("#{@transcript_dir}/agent-one.jsonl", "{}")
    @file_system.write("#{@transcript_dir}/agent-two.jsonl", "{}")
    @file_system.write("#{@transcript_dir}/main.jsonl", "{}")

    result = @source.discover_subagent_files(working_directory: @working_directory)

    assert_equal [ "#{@transcript_dir}/agent-one.jsonl", "#{@transcript_dir}/agent-two.jsonl" ], result.sort
  end

  test "discover_subagent_files returns empty array without a working_directory" do
    assert_equal [], @source.discover_subagent_files(working_directory: nil)
  end

  # === mcp_log_paths ===

  test "mcp_log_paths returns the per-session MCP cache base directory" do
    result = @source.mcp_log_paths(working_directory: @working_directory)

    assert_equal [ File.join(PathSanitizer.cache_base, "-tmp-test-clone") ], result
  end

  test "mcp_log_paths returns empty array without a working_directory" do
    assert_equal [], @source.mcp_log_paths(working_directory: nil)
  end
end
