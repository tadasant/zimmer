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

    # Stub the controller's path methods to use our isolated temp directory
    Api::V1::TranscriptArchivesController.any_instance.stubs(:archive_path).returns(Pathname.new(@archive_path))
    Api::V1::TranscriptArchivesController.any_instance.stubs(:metadata_path).returns(Pathname.new(@metadata_path))
  end

  teardown do
    ENV.delete("API_KEYS")
    FileUtils.rm_rf(@test_dir) if @test_dir && File.directory?(@test_dir)
    Api::V1::TranscriptArchivesController.any_instance.unstub(:archive_path)
    Api::V1::TranscriptArchivesController.any_instance.unstub(:metadata_path)
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

  test "download returns 404 when no archive exists" do
    get api_v1_transcript_archive_download_path, headers: @headers
    assert_response :not_found

    json = JSON.parse(response.body)
    assert_equal "Not Found", json["error"]
    assert_includes json["message"], "No transcript archive exists yet"
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

    assert_equal "2026-01-15T10:30:00Z", response.headers["X-Archive-Generated-At"]
    assert_equal "42", response.headers["X-Archive-Session-Count"]
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
  end

  test "status returns metadata when archive exists" do
    create_test_archive
    create_test_metadata(generated_at: "2026-01-15T10:30:00Z", session_count: 5, file_size_bytes: 12345)

    get api_v1_transcript_archive_status_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal "2026-01-15T10:30:00Z", json["generated_at"]
    assert_equal 5, json["session_count"]
    assert_equal 12345, json["file_size_bytes"]
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
