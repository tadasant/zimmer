# frozen_string_literal: true

require "test_helper"
require "zip"

class Api::V1::TranscriptArchivesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key

    # Use a unique temp directory per test to avoid parallel test interference
    @test_dir = Dir.mktmpdir("transcript_archive_test")
    @archive_path = File.join(@test_dir, "latest.zip")
    @metadata_path = File.join(@test_dir, "latest_metadata.json")

    # Point the real resolver at the isolated directory, rather than stubbing the
    # controller: this exercises the same path the job and every other reader take.
    @previous_archive_dir = ENV["AGENT_TRANSCRIPT_ARCHIVE_DIR"]
    ENV["AGENT_TRANSCRIPT_ARCHIVE_DIR"] = @test_dir
  end

  teardown do
    ENV.delete("API_KEYS")
    ENV["AGENT_TRANSCRIPT_ARCHIVE_DIR"] = @previous_archive_dir
    ENV.delete("AGENT_TRANSCRIPT_ARCHIVE_DIR") if @previous_archive_dir.nil?
    FileUtils.rm_rf(@test_dir) if @test_dir && File.directory?(@test_dir)
  end

  # Authentication tests

  test "download returns 401 without API key" do
    get api_v1_transcript_archive_download_path
    assert_response :unauthorized
  end

  test "status returns 401 without API key" do
    get api_v1_transcript_archive_status_path
    assert_response :unauthorized
  end

  # Download endpoint tests

  test "download returns 404 naming the state and the path it looked at" do
    get api_v1_transcript_archive_download_path, headers: @headers
    assert_response :not_found

    json = JSON.parse(response.body)
    assert_equal "Not Found", json["error"]
    assert_equal "never_built", json["state"]
    assert_equal @archive_path, json["archive_path"]
    assert_includes json["message"], "No transcript archive has ever been built at #{@archive_path}"
    # The claim it replaced asserted a recovery the caller could not verify (#714).
    assert_not_includes json["message"], "is built every 10 minutes"
  end

  test "download serves zip file when archive exists" do
    create_test_archive

    get api_v1_transcript_archive_download_path, headers: @headers
    assert_response :success
    assert_equal "application/zip", response.content_type
  end

  test "download includes custom headers" do
    create_test_archive
    create_test_metadata(generated_at: "2026-01-15T10:30:00Z", session_count: 42)

    get api_v1_transcript_archive_download_path, headers: @headers
    assert_response :success

    assert_equal Time.zone.parse("2026-01-15T10:30:00Z").iso8601, response.headers["X-Archive-Generated-At"]
    assert_equal "42", response.headers["X-Archive-Session-Count"]
    assert_equal "true", response.headers["X-Archive-Stale"], "a 2026-01 archive is long past its rebuild window"
  end

  test "download sets attachment disposition" do
    create_test_archive

    get api_v1_transcript_archive_download_path, headers: @headers
    assert_response :success

    assert_includes response.headers["Content-Disposition"], "attachment"
    assert_includes response.headers["Content-Disposition"], "transcript_archive_"
  end

  # Status endpoint tests

  test "status returns 404 when no archive exists" do
    get api_v1_transcript_archive_status_path, headers: @headers
    assert_response :not_found

    json = JSON.parse(response.body)
    assert_equal "Not Found", json["error"]
    assert_equal "never_built", json["state"]
  end

  test "status tells a vanished archive apart from one that was never built" do
    create_test_metadata_without_archive(generated_at: "2026-01-15T10:30:00Z", session_count: 12)

    get api_v1_transcript_archive_status_path, headers: @headers
    assert_response :not_found

    json = JSON.parse(response.body)
    assert_equal "missing", json["state"]
    assert_includes json["message"], "12 session(s)"
  end

  test "status returns metadata when archive exists" do
    create_test_archive
    create_test_metadata(generated_at: "2026-01-15T10:30:00Z", session_count: 5, file_size_bytes: 12345)

    get api_v1_transcript_archive_status_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal Time.zone.parse("2026-01-15T10:30:00Z").iso8601, json["generated_at"]
    assert_equal 5, json["session_count"]
    assert_equal 12345, json["file_size_bytes"]
    assert_equal "present", json["state"]
    assert json["stale"], "an archive from January is stale in August"
    assert_includes json["stale_reason"], "transcript_archive"
  end

  test "status reports a fresh archive as not stale" do
    create_test_archive
    create_test_metadata(generated_at: 2.minutes.ago.iso8601, session_count: 5)

    get api_v1_transcript_archive_status_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_not json["stale"]
    assert_nil json["stale_reason"]
  end

  test "status returns file size from disk when metadata is missing size" do
    create_test_archive
    create_test_metadata(generated_at: "2026-01-15T10:30:00Z", session_count: 1)

    get api_v1_transcript_archive_status_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["file_size_bytes"] > 0, "Should return actual file size"
  end

  test "status handles corrupt metadata gracefully" do
    create_test_archive
    File.write(@metadata_path, "not valid json{{{")

    get api_v1_transcript_archive_status_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 0, json["session_count"]
  end

  private

  def create_test_archive
    Zip::OutputStream.open(@archive_path) do |zip|
      zip.put_next_entry("manifest.json")
      zip.write(JSON.generate({ session_count: 1, generated_at: Time.current.iso8601, session_ids: [] }))
    end
  end

  def create_test_metadata_without_archive(generated_at:, session_count:)
    File.write(@metadata_path, JSON.generate({
      "generated_at" => generated_at, "session_count" => session_count, "sessions" => {}
    }))
  end

  def create_test_metadata(generated_at: Time.current.iso8601, session_count: 0, file_size_bytes: nil)
    metadata = {
      "generated_at" => generated_at,
      "session_count" => session_count,
      "file_size_bytes" => file_size_bytes || File.size(@archive_path),
      "sessions" => {}
    }
    File.write(@metadata_path, JSON.generate(metadata))
  end
end
