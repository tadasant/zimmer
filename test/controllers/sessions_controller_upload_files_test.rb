require "test_helper"
require "mocha/minitest"

class SessionsControllerUploadFilesTest < ActionDispatch::IntegrationTest
  def setup
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)

    @session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test"
    )
    @temp_session_id = "temp_#{SecureRandom.uuid}"
  end

  def teardown
    FileStorageService.new(session_id: @session.id).cleanup! if @session&.persisted?
    FileStorageService.new(session_id: @temp_session_id).cleanup!
    Mocha::Mockery.instance.teardown
  end

  def make_upload(content:, filename:, content_type: "text/plain")
    Rack::Test::UploadedFile.new(
      StringIO.new(content),
      content_type,
      original_filename: filename
    )
  end

  test "uploads a single file to an existing session" do
    upload = make_upload(content: "hello world", filename: "notes.md", content_type: "text/markdown")

    post upload_files_session_url(@session), params: { files: [ upload ] }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["files"].length
    file = body["files"].first
    assert_equal "notes.md", file["original_filename"]
    assert_equal "hello world".bytesize, file["size"]
    assert File.exist?(file["path"])
    assert file["path"].include?(@session.id.to_s)
  end

  test "uploads multiple files to an existing session" do
    a = make_upload(content: "alpha", filename: "a.txt")
    b = make_upload(content: "beta beta", filename: "b.log")

    post upload_files_session_url(@session), params: { files: [ a, b ] }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body["files"].length

    filenames = body["files"].map { |f| f["original_filename"] }.sort
    assert_equal [ "a.txt", "b.log" ], filenames
  end

  test "uploads file with temp_session_id (pre-session upload)" do
    upload = make_upload(content: "preupload", filename: "draft.md")

    post upload_files_new_session_sessions_url, params: {
      temp_session_id: @temp_session_id,
      files: [ upload ]
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["files"].length
    assert_equal "draft.md", body["files"].first["original_filename"]
    assert body["files"].first["path"].include?(@temp_session_id)
  end

  test "rejects invalid temp_session_id format" do
    upload = make_upload(content: "x", filename: "x.txt")

    post upload_files_new_session_sessions_url, params: {
      temp_session_id: "not-a-temp-id",
      files: [ upload ]
    }

    assert_response :unprocessable_entity
    assert_match(/Invalid temp_session_id/, JSON.parse(response.body)["error"])
  end

  test "rejects when neither id nor temp_session_id provided" do
    upload = make_upload(content: "x", filename: "x.txt")

    post upload_files_new_session_sessions_url, params: { files: [ upload ] }

    assert_response :unprocessable_entity
    assert_match(/required/i, JSON.parse(response.body)["error"])
  end

  test "MAX_FILES_PER_REQUEST is 200" do
    assert_equal 200, SessionsController::MAX_FILES_PER_REQUEST
  end

  test "rejects when more than MAX_FILES_PER_REQUEST files uploaded" do
    too_many = (0..SessionsController::MAX_FILES_PER_REQUEST).map do |i|
      make_upload(content: "x", filename: "f#{i}.txt")
    end

    post upload_files_session_url(@session), params: { files: too_many }

    assert_response :unprocessable_entity
    assert_match(/Maximum/, JSON.parse(response.body)["error"])
  end

  test "accepts the maximum allowed number of files in one request" do
    at_limit = (1..SessionsController::MAX_FILES_PER_REQUEST).map do |i|
      make_upload(content: "x", filename: "f#{i}.txt")
    end

    post upload_files_session_url(@session), params: { files: at_limit }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal SessionsController::MAX_FILES_PER_REQUEST, body["files"].length
  end

  test "rejects when no valid files provided" do
    post upload_files_session_url(@session), params: { files: [] }

    assert_response :unprocessable_entity
    assert_match(/No valid files/, JSON.parse(response.body)["error"])
  end

  test "rejects file exceeding maximum size" do
    # Override MAX_FILE_SIZE so we don't have to allocate a literal 500MB+
    # string here. The bound check in FileStorageService is what we exercise.
    original = FileStorageService::MAX_FILE_SIZE
    FileStorageService.send(:remove_const, :MAX_FILE_SIZE)
    FileStorageService.const_set(:MAX_FILE_SIZE, 1.kilobyte)
    begin
      big = "x" * (FileStorageService::MAX_FILE_SIZE + 1)
      upload = make_upload(content: big, filename: "big.bin", content_type: "application/octet-stream")

      post upload_files_session_url(@session), params: { files: [ upload ] }

      assert_response :unprocessable_entity
    ensure
      FileStorageService.send(:remove_const, :MAX_FILE_SIZE)
      FileStorageService.const_set(:MAX_FILE_SIZE, original)
    end
  end

  test "stored file content is preserved exactly" do
    binary_blob = (0..255).to_a.pack("C*")
    upload = make_upload(content: binary_blob, filename: "blob.bin", content_type: "application/octet-stream")

    post upload_files_session_url(@session), params: { files: [ upload ] }

    assert_response :success
    body = JSON.parse(response.body)
    stored = File.binread(body["files"].first["path"])
    assert_equal binary_blob, stored
  end

  test "sanitizes hostile filenames before storing" do
    # Use a name that retains path-like characters after Rack strips the path —
    # we test the service-layer sanitization here, since Rack already calls
    # File.basename on the original_filename.
    upload = make_upload(content: "x", filename: "weird;name with spaces.txt")

    post upload_files_session_url(@session), params: { files: [ upload ] }

    assert_response :success
    body = JSON.parse(response.body)
    stored_basename = File.basename(body["files"].first["path"])
    refute_includes stored_basename, ";"
    refute_includes stored_basename, " "
    refute_includes stored_basename, "/"
    refute_includes stored_basename, ".."
    # Original filename is reported back to the UI exactly as Rack delivered it
    # (Rack.basename'd, but otherwise unchanged).
    assert_equal "weird;name with spaces.txt", body["files"].first["original_filename"]
  end
end
