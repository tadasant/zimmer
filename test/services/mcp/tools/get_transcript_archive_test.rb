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

  test "raises with the observed state, and the path it observed, when nothing was ever built" do
    error = assert_raises(Mcp::ToolError) { @tool.call({}) }

    assert_match(/No transcript archive has ever been built at #{Regexp.escape(@archive_path.to_s)}/, error.message)
    assert_match(/Waiting will not help on its own/, error.message)
    # The old message told every caller the failure was transient and cost them ten
    # minutes before they found out otherwise (#714).
    refute_match(/is built every 10 minutes/, error.message)
  end

  test "distinguishes a vanished archive from one that was never built" do
    File.write(@metadata_path, { generated_at: "2026-08-30T09:00:00Z", session_count: 12 }.to_json)

    error = assert_raises(Mcp::ToolError) { @tool.call({}) }

    assert_match(/missing at #{Regexp.escape(@archive_path.to_s)}/, error.message)
    assert_match(/12 session\(s\)/, error.message)
  end

  test "reports a stale archive as stale rather than withholding it" do
    File.binwrite(@archive_path, "zip-bytes")
    File.write(@metadata_path, {
      generated_at: 5.hours.ago.iso8601, session_count: 3, file_size_bytes: 1024
    }.to_json)

    output = @tool.call({})

    assert_match(/- \*\*Stale:\*\* yes — This archive was built 5\.0 hours ago/, output)
    assert_includes output, "**URL:** `https://zimmer.test/api/v1/transcript_archive/download`"
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
    assert_includes output, "- **Stale:** yes"
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
    assert_includes output, "- **Stale:** no"
  end

  test "points content search at quick_search_sessions rather than at this download" do
    description = Mcp::Tools::GetTranscriptArchive.rendered_description

    assert_includes description, "quick_search_sessions"
    assert_includes description, "search_contents"
  end
end
