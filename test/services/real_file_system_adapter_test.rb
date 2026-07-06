# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class RealFileSystemAdapterTest < ActiveSupport::TestCase
  setup do
    @adapter = RealFileSystemAdapter.new
    @temp_dir = Dir.mktmpdir("file_system_adapter_test")
  end

  teardown do
    FileUtils.rm_rf(@temp_dir) if File.exist?(@temp_dir)
  end

  test "writes and reads file content" do
    path = File.join(@temp_dir, "test.txt")
    content = "Hello, World!"

    bytes_written = @adapter.write(path, content)

    assert_equal content.bytesize, bytes_written
    assert_equal content, @adapter.read(path)
  end

  test "write with options" do
    path = File.join(@temp_dir, "test.txt")

    @adapter.write(path, "first line\n", mode: "w")
    @adapter.write(path, "second line\n", mode: "a")

    assert_equal "first line\nsecond line\n", @adapter.read(path)
  end

  test "exists? returns true for existing file" do
    path = File.join(@temp_dir, "test.txt")
    @adapter.write(path, "content")

    assert @adapter.exists?(path)
  end

  test "exists? returns false for non-existent file" do
    path = File.join(@temp_dir, "nonexistent.txt")

    assert_not @adapter.exists?(path)
  end

  test "exists? returns true for existing directory" do
    path = File.join(@temp_dir, "subdir")
    @adapter.mkdir_p(path)

    assert @adapter.exists?(path)
  end

  test "directory? returns true for directory" do
    path = File.join(@temp_dir, "subdir")
    @adapter.mkdir_p(path)

    assert @adapter.directory?(path)
  end

  test "directory? returns false for file" do
    path = File.join(@temp_dir, "test.txt")
    @adapter.write(path, "content")

    assert_not @adapter.directory?(path)
  end

  test "directory? returns false for non-existent path" do
    path = File.join(@temp_dir, "nonexistent")

    assert_not @adapter.directory?(path)
  end

  test "glob finds matching files" do
    @adapter.write(File.join(@temp_dir, "file1.txt"), "a")
    @adapter.write(File.join(@temp_dir, "file2.txt"), "b")
    @adapter.write(File.join(@temp_dir, "file3.rb"), "c")

    matches = @adapter.glob(File.join(@temp_dir, "*.txt"))

    assert_equal 2, matches.length
    assert_includes matches, File.join(@temp_dir, "file1.txt")
    assert_includes matches, File.join(@temp_dir, "file2.txt")
  end

  test "glob with recursive pattern" do
    @adapter.mkdir_p(File.join(@temp_dir, "subdir"))
    @adapter.write(File.join(@temp_dir, "root.txt"), "a")
    @adapter.write(File.join(@temp_dir, "subdir", "nested.txt"), "b")

    matches = @adapter.glob(File.join(@temp_dir, "**", "*.txt"))

    assert_equal 2, matches.length
    assert_includes matches, File.join(@temp_dir, "root.txt")
    assert_includes matches, File.join(@temp_dir, "subdir", "nested.txt")
  end

  test "mtime returns modification time" do
    path = File.join(@temp_dir, "test.txt")
    before_write = Time.current - 1.second # Allow for timing precision

    @adapter.write(path, "content")
    mtime = @adapter.mtime(path)

    assert mtime >= before_write
    assert mtime <= Time.current + 1.second # Allow for timing precision
  end

  test "mtime raises error for non-existent file" do
    path = File.join(@temp_dir, "nonexistent.txt")

    assert_raises(Errno::ENOENT) { @adapter.mtime(path) }
  end

  test "mkdir_p creates directory and parents" do
    path = File.join(@temp_dir, "a", "b", "c")

    @adapter.mkdir_p(path)

    assert @adapter.directory?(path)
    assert @adapter.directory?(File.join(@temp_dir, "a"))
    assert @adapter.directory?(File.join(@temp_dir, "a", "b"))
  end

  test "mkdir_p is idempotent" do
    path = File.join(@temp_dir, "subdir")

    @adapter.mkdir_p(path)
    @adapter.mkdir_p(path) # Should not raise error

    assert @adapter.directory?(path)
  end

  test "rm_rf removes file" do
    path = File.join(@temp_dir, "test.txt")
    @adapter.write(path, "content")

    @adapter.rm_rf(path)

    assert_not @adapter.exists?(path)
  end

  test "rm_rf removes directory and contents recursively" do
    dir_path = File.join(@temp_dir, "to_remove")
    @adapter.mkdir_p(dir_path)
    @adapter.write(File.join(dir_path, "file1.txt"), "a")
    @adapter.mkdir_p(File.join(dir_path, "subdir"))
    @adapter.write(File.join(dir_path, "subdir", "file2.txt"), "b")

    @adapter.rm_rf(dir_path)

    assert_not @adapter.exists?(dir_path)
    assert_not @adapter.exists?(File.join(dir_path, "file1.txt"))
    assert_not @adapter.exists?(File.join(dir_path, "subdir"))
  end

  test "rm_rf on non-existent path does not raise error" do
    path = File.join(@temp_dir, "nonexistent")

    assert_nothing_raised { @adapter.rm_rf(path) }
  end

  test "read raises error for non-existent file" do
    path = File.join(@temp_dir, "nonexistent.txt")

    assert_raises(Errno::ENOENT) { @adapter.read(path) }
  end

  test "chmod changes file permissions" do
    path = File.join(@temp_dir, "script.sh")
    @adapter.write(path, "#!/bin/bash\necho test")

    result = @adapter.chmod(0o755, path)

    assert_equal 1, result # chmod returns number of files changed
    stat = File.stat(path)
    assert_equal 0o100755, stat.mode # Verify executable bit set
  end

  test "chmod raises error for non-existent file" do
    path = File.join(@temp_dir, "nonexistent.sh")

    assert_raises(Errno::ENOENT) { @adapter.chmod(0o755, path) }
  end
end
