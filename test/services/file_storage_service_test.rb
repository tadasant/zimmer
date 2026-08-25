require "test_helper"
require "mocha/minitest"

# Covers what is genuinely FileStorageService's own: storing arbitrary bytes,
# filename sanitisation, and the 500MB bound. The lifecycle it shares with
# ImageStorageService — resolved storage paths, session_id validation, the
# exists? traversal guard, list, cleanup, copy_from_temp — is asserted by
# SessionAttachmentStorageConformance, which runs against both subclasses.
class FileStorageServiceTest < ActiveSupport::TestCase
  include SessionAttachmentStorageConformance

  def storage_class = FileStorageService
  def storage_env_var = "AGENT_FILES_DIR"
  def expected_storage_subdir = "agent-orchestrator-files"
  def expected_attachment_noun = "file"

  # Conformance hook: store one attachment and return its metadata.
  def store_sample(service, filename: nil)
    service.store(data: "sample-#{SecureRandom.hex(4)}", filename: "#{filename || 'sample'}.txt")
  end

  def setup
    @service = conformance_service
  end

  test "stores file from raw data" do
    result = @service.store(data: "hello world", filename: "notes.md")

    assert result[:path].present?
    assert result[:path].start_with?(@service.session_dir)
    assert_equal "notes.md", result[:original_filename]
    assert_equal "hello world".bytesize, result[:size]
    assert File.exist?(result[:path])
    assert_equal "hello world", File.binread(result[:path])
  end

  test "stores file from uploaded file" do
    uploaded = mock("uploaded_file")
    uploaded.stubs(:read).returns("file contents here")
    uploaded.stubs(:original_filename).returns("server.log")

    result = @service.store(uploaded_file: uploaded)

    assert_equal "server.log", result[:original_filename]
    assert File.exist?(result[:path])
    assert_equal "file contents here", File.binread(result[:path])
  end

  test "preserves binary content" do
    binary_blob = (0..255).to_a.pack("C*")
    result = @service.store(data: binary_blob, filename: "blob.bin")

    assert_equal binary_blob, File.binread(result[:path])
  end

  test "sanitizes filename to prevent path traversal" do
    result = @service.store(data: "x", filename: "../../etc/passwd")

    assert File.dirname(result[:path]) == @service.session_dir
    refute_includes File.basename(result[:path]), "/"
    refute_includes File.basename(result[:path]), ".."
  end

  test "sanitizes shell metacharacters in filename" do
    result = @service.store(data: "x", filename: "weird name;rm -rf $HOME.txt")

    basename = File.basename(result[:path])
    refute_match(/[;\s$]/, basename)
    assert basename.end_with?(".txt")
  end

  test "preserves extension when truncating long filenames" do
    long_name = ("a" * 500) + ".log"
    result = @service.store(data: "x", filename: long_name)

    basename = File.basename(result[:path])
    # Should still end in .log even after truncation
    assert basename.end_with?(".log")
  end

  test "rejects empty filename" do
    assert_raises(FileStorageService::InvalidFileError) do
      @service.store(data: "x", filename: "")
    end
  end

  test "rejects nil filename for data uploads" do
    assert_raises(FileStorageService::InvalidFileError) do
      @service.store(data: "x")
    end
  end

  test "rejects no data" do
    assert_raises(FileStorageService::InvalidFileError) do
      @service.store
    end
  end

  test "max file size is 500MB" do
    assert_equal 500.megabytes, FileStorageService::MAX_FILE_SIZE
  end

  test "rejects files that are too large" do
    # Temporarily override MAX_FILE_SIZE so we don't have to allocate a literal
    # 500MB+ string in the test process; the bound check is what we're exercising.
    with_max_file_size(1.kilobyte) do
      large = "x" * (FileStorageService::MAX_FILE_SIZE + 1)

      assert_raises(FileStorageService::InvalidFileError) do
        @service.store(data: large, filename: "big.bin")
      end
    end
  end

  test "accepts files just at the max size" do
    with_max_file_size(1.kilobyte) do
      at_limit = "x" * FileStorageService::MAX_FILE_SIZE
      result = @service.store(data: at_limit, filename: "ok.bin")
      assert File.exist?(result[:path])
    end
  end

  test "creates unique paths for each stored file" do
    r1 = @service.store(data: "x", filename: "same.txt")
    r2 = @service.store(data: "y", filename: "same.txt")

    refute_equal r1[:path], r2[:path]
    assert_equal "same.txt", r1[:original_filename]
    assert_equal "same.txt", r2[:original_filename]
  end

  test "copy_from_temp recovers the sanitized original basename" do
    temp_id = "temp_#{SecureRandom.uuid}"
    temp_service = FileStorageService.new(session_id: temp_id)
    temp_service.store(data: "hello", filename: "greet.txt")
    temp_service.store(data: "world", filename: "second.md")

    real_service = conformance_other_service
    copied = FileStorageService.copy_from_temp(
      temp_session_id: temp_id,
      new_session_id: real_service.session_id.to_i
    )

    assert_equal 2, copied.length
    # The stored basename is "<unique_id>-<sanitized_original>"; the copy strips
    # the old unique_id so the new entry keeps a clean original filename.
    assert_equal [ "greet.txt", "second.md" ], copied.map { |c| c[:original_filename] }.sort
    copied.each { |c| refute_match(/\A[a-f0-9]+-[a-f0-9]+-/, File.basename(c[:path])) }
  ensure
    temp_service&.cleanup!
  end

  private

  def with_max_file_size(value)
    original = FileStorageService::MAX_FILE_SIZE
    FileStorageService.send(:remove_const, :MAX_FILE_SIZE)
    FileStorageService.const_set(:MAX_FILE_SIZE, value)
    yield
  ensure
    FileStorageService.send(:remove_const, :MAX_FILE_SIZE)
    FileStorageService.const_set(:MAX_FILE_SIZE, original)
  end
end
