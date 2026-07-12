# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"


class Mcp::Tools::GetTranscriptArchiveTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::GetTranscriptArchive.new(
      context: Mcp::Context.new(tool_groups: "sessions", base_url: "https://zimmer.test/")
    )

    # Isolated temp paths so a real (or missing) storage/ archive cannot sway the test.
    @test_dir = Dir.mktmpdir("mcp_transcript_archive_test")
    @archive_path = Pathname.new(File.join(@test_dir, "latest.zip"))
    @metadata_path = Pathname.new(File.join(@test_dir, "latest_metadata.json"))

    Mcp::Tools::GetTranscriptArchive.any_instance.stubs(:archive_path).returns(@archive_path)
    Mcp::Tools::GetTranscriptArchive.any_instance.stubs(:metadata_path).returns(@metadata_path)
  end

  teardown do
    Mcp::Tools::GetTranscriptArchive.any_instance.unstub(:archive_path)
    Mcp::Tools::GetTranscriptArchive.any_instance.unstub(:metadata_path)
    FileUtils.rm_rf(@test_dir) if @test_dir && File.directory?(@test_dir)
  end

  test "raises when no archive has been built yet" do
    error = assert_raises(Mcp::ToolError) { @tool.call({}) }
    assert_match(/No transcript archive exists yet/, error.message)
  end

  test "returns metadata and an absolute download URL" do
    File.binwrite(@archive_path, "zip-bytes")
    File.write(@metadata_path, {
      generated_at: "2026-07-12T00:00:00Z",
      session_count: 42,
      file_size_bytes: 2_097_152
    }.to_json)

    output = @tool.call({})

    assert_includes output, "## Transcript Archive"
    assert_includes output, "- **Generated At:** 2026-07-12T00:00:00Z"
    assert_includes output, "- **Session Count:** 42"
    assert_includes output, "- **File Size:** 2.0 MB"
    assert_includes output, "**URL:** `https://zimmer.test/api/v1/transcript_archive/download`"
    assert_includes output, 'curl -o /path/to/transcript-archive.zip -H "X-API-Key:'
  end

  test "falls back to the archive file size when metadata is unreadable" do
    File.binwrite(@archive_path, "x" * 2048)
    File.write(@metadata_path, "not json")

    output = @tool.call({})

    assert_includes output, "- **Session Count:** 0"
    assert_includes output, "- **File Size:** 2.0 KB"
  end
end
