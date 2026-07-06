require "test_helper"
require "mocha/minitest"

class FileStorageServiceTest < ActiveSupport::TestCase
  def setup
    @session_id = rand(100_000_000..999_999_999)
    @service = FileStorageService.new(session_id: @session_id)
    FileUtils.rm_rf(@service.session_dir)
  end

  def teardown
    FileUtils.rm_rf(@service.session_dir)
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

  test "validates path is within session directory" do
    refute @service.exists?("/etc/passwd")
    refute @service.exists?("/tmp/agent-orchestrator-files/other-session/file.txt")
    refute @service.exists?(nil)
  end

  test "exists? confirms stored file" do
    result = @service.store(data: "x", filename: "notes.md")
    assert @service.exists?(result[:path])
  end

  test "prevents path traversal via dot-dot in exists?" do
    @service.store(data: "x", filename: "notes.md")

    refute @service.exists?(@service.session_dir + "/../../../etc/passwd")
    refute @service.exists?("#{@service.session_dir}/sub/../../../etc/passwd")
    refute @service.exists?("/tmp/agent-orchestrator-files/#{@session_id}/../other/file")
  end

  test "rejects invalid session_id types" do
    assert_raises(ArgumentError) { FileStorageService.new(session_id: "123") }
    assert_raises(ArgumentError) { FileStorageService.new(session_id: nil) }
    assert_raises(ArgumentError) { FileStorageService.new(session_id: -1) }
    assert_raises(ArgumentError) { FileStorageService.new(session_id: 0) }
    assert_raises(ArgumentError) { FileStorageService.new(session_id: "../123") }
  end

  test "accepts temp_<uuid> session_id format for pre-session uploads" do
    uuid = SecureRandom.uuid
    service = FileStorageService.new(session_id: "temp_#{uuid}")
    assert_equal "temp_#{uuid}", service.session_id
  end

  test "lists files for session" do
    @service.store(data: "a", filename: "one.txt")
    @service.store(data: "b", filename: "two.txt")

    files = @service.list

    assert_equal 2, files.length
    files.each { |path| assert File.exist?(path) }
  end

  test "cleans up session files" do
    result = @service.store(data: "x", filename: "notes.md")
    assert File.exist?(result[:path])

    @service.cleanup!

    refute File.exist?(result[:path])
    refute File.directory?(@service.session_dir)
  end

  test "creates unique paths for each stored file" do
    r1 = @service.store(data: "x", filename: "same.txt")
    r2 = @service.store(data: "y", filename: "same.txt")

    refute_equal r1[:path], r2[:path]
    assert_equal "same.txt", r1[:original_filename]
    assert_equal "same.txt", r2[:original_filename]
  end

  test "copy_from_temp moves files from temp session to real session" do
    temp_id = "temp_#{SecureRandom.uuid}"
    temp_service = FileStorageService.new(session_id: temp_id)
    temp_service.store(data: "hello", filename: "greet.txt")
    temp_service.store(data: "world", filename: "second.md")

    real_id = rand(100_000_000..999_999_999)
    copied = FileStorageService.copy_from_temp(temp_session_id: temp_id, new_session_id: real_id)

    real_service = FileStorageService.new(session_id: real_id)
    begin
      assert_equal 2, copied.length
      copied.each { |c| assert File.exist?(c[:path]) }
      assert_equal 2, real_service.list.length

      # Original filenames should be preserved on the new entries
      filenames = copied.map { |c| c[:original_filename] }.sort
      assert_equal [ "greet.txt", "second.md" ], filenames

      # Temp directory should be cleaned up
      refute File.directory?(temp_service.session_dir)
    ensure
      real_service.cleanup!
    end
  end

  test "session_dir is namespaced by session_id" do
    other = FileStorageService.new(session_id: @session_id + 1)
    refute_equal @service.session_dir, other.session_dir
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
