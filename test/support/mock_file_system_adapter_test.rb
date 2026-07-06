# frozen_string_literal: true

require "test_helper"

class MockFileSystemAdapterTest < ActiveSupport::TestCase
  setup do
    @adapter = MockFileSystemAdapter.new
  end

  test "writes and reads file content" do
    path = "/fake/path.txt"
    content = "Hello, World!"

    bytes_written = @adapter.write(path, content)

    assert_equal content.bytesize, bytes_written
    assert_equal content, @adapter.read(path)
  end

  test "exists? returns true for written file" do
    @adapter.write("/fake/file.txt", "content")

    assert @adapter.exists?("/fake/file.txt")
  end

  test "exists? returns false for non-existent file" do
    assert_not @adapter.exists?("/nonexistent.txt")
  end

  test "exists? returns true for created directory" do
    @adapter.mkdir_p("/fake/dir")

    assert @adapter.exists?("/fake/dir")
  end

  test "directory? returns true for created directory" do
    @adapter.mkdir_p("/fake/dir")

    assert @adapter.directory?("/fake/dir")
  end

  test "directory? returns false for file" do
    @adapter.write("/fake/file.txt", "content")

    assert_not @adapter.directory?("/fake/file.txt")
  end

  test "directory? returns false for non-existent path" do
    assert_not @adapter.directory?("/nonexistent")
  end

  test "glob finds matching files with simple pattern" do
    @adapter.write("/fake/file1.txt", "a")
    @adapter.write("/fake/file2.txt", "b")
    @adapter.write("/fake/file3.rb", "c")

    matches = @adapter.glob("/fake/*.txt")

    assert_equal 2, matches.length
    assert_includes matches, "/fake/file1.txt"
    assert_includes matches, "/fake/file2.txt"
  end

  test "glob finds matching files with recursive pattern" do
    @adapter.write("/fake/nested.txt", "a")
    @adapter.write("/fake/deep/file.txt", "b")
    @adapter.write("/another/path.txt", "c")

    matches = @adapter.glob("/**/*.txt")

    assert_equal 3, matches.length
    assert_includes matches, "/fake/nested.txt"
    assert_includes matches, "/fake/deep/file.txt"
    assert_includes matches, "/another/path.txt"
  end

  test "glob returns sorted results" do
    @adapter.write("/c.txt", "1")
    @adapter.write("/a.txt", "2")
    @adapter.write("/b.txt", "3")

    matches = @adapter.glob("/*.txt")

    assert_equal [ "/a.txt", "/b.txt", "/c.txt" ], matches
  end

  test "glob matches question mark as single character" do
    @adapter.write("/file1.txt", "a")
    @adapter.write("/file2.txt", "b")
    @adapter.write("/file10.txt", "c")

    matches = @adapter.glob("/file?.txt")

    assert_equal 2, matches.length
    assert_includes matches, "/file1.txt"
    assert_includes matches, "/file2.txt"
  end

  test "mtime returns time for written file" do
    path = "/fake/file.txt"
    before_write = Time.current

    @adapter.write(path, "content")
    mtime = @adapter.mtime(path)

    assert mtime >= before_write
    assert mtime <= Time.current
  end

  test "mtime raises error for non-existent file" do
    assert_raises(Errno::ENOENT) { @adapter.mtime("/nonexistent.txt") }
  end

  test "mtime updates on write" do
    path = "/fake/file.txt"
    @adapter.write(path, "first")
    first_mtime = @adapter.mtime(path)

    # Ensure time has advanced
    travel 1.second do
      @adapter.write(path, "second")
      second_mtime = @adapter.mtime(path)

      assert second_mtime > first_mtime
    end
  end

  test "mkdir_p creates directory" do
    @adapter.mkdir_p("/fake/dir")

    assert @adapter.directory?("/fake/dir")
  end

  test "mkdir_p creates parent directories" do
    @adapter.mkdir_p("/fake/a/b/c")

    assert @adapter.directory?("/fake/a/b/c")
    assert @adapter.directory?("/fake/a/b")
    assert @adapter.directory?("/fake/a")
  end

  test "mkdir_p is idempotent" do
    @adapter.mkdir_p("/fake/dir")
    @adapter.mkdir_p("/fake/dir")

    assert @adapter.directory?("/fake/dir")
  end

  test "rm_rf removes file" do
    @adapter.write("/fake/file.txt", "content")

    @adapter.rm_rf("/fake/file.txt")

    assert_not @adapter.exists?("/fake/file.txt")
  end

  test "rm_rf removes directory" do
    @adapter.mkdir_p("/fake/dir")

    @adapter.rm_rf("/fake/dir")

    assert_not @adapter.exists?("/fake/dir")
  end

  test "rm_rf removes directory and child files recursively" do
    @adapter.write("/fake/dir/file1.txt", "a")
    @adapter.write("/fake/dir/file2.txt", "b")

    @adapter.rm_rf("/fake/dir")

    assert_not @adapter.exists?("/fake/dir")
    assert_not @adapter.exists?("/fake/dir/file1.txt")
    assert_not @adapter.exists?("/fake/dir/file2.txt")
  end

  test "rm_rf removes nested directories" do
    @adapter.mkdir_p("/fake/dir/subdir")
    @adapter.write("/fake/dir/subdir/file.txt", "content")

    @adapter.rm_rf("/fake/dir")

    assert_not @adapter.exists?("/fake/dir/subdir")
    assert_not @adapter.exists?("/fake/dir/subdir/file.txt")
  end

  test "rm_rf on non-existent path does not raise error" do
    assert_nothing_raised { @adapter.rm_rf("/nonexistent") }
  end

  test "read raises error for non-existent file" do
    error = assert_raises(Errno::ENOENT) { @adapter.read("/nonexistent.txt") }
    assert_match(/nonexistent\.txt/, error.message)
  end

  test "clear resets all state" do
    @adapter.write("/file.txt", "content")
    @adapter.mkdir_p("/dir")

    @adapter.clear

    assert_not @adapter.exists?("/file.txt")
    assert_not @adapter.exists?("/dir")
    assert_empty @adapter.files
    assert_empty @adapter.directories
  end

  test "files and directories are accessible for inspection" do
    @adapter.write("/file1.txt", "content1")
    @adapter.write("/file2.txt", "content2")
    @adapter.mkdir_p("/dir")

    assert_equal 2, @adapter.files.size
    assert_equal "content1", @adapter.files["/file1.txt"]
    assert_equal "content2", @adapter.files["/file2.txt"]
    assert_includes @adapter.directories, "/dir"
  end

  test "chmod succeeds for existing file" do
    @adapter.write("/script.sh", "#!/bin/bash")

    result = @adapter.chmod(0o755, "/script.sh")

    assert_equal 0, result
  end

  test "chmod raises error for non-existent file" do
    error = assert_raises(Errno::ENOENT) { @adapter.chmod(0o755, "/nonexistent.sh") }
    assert_match(/nonexistent\.sh/, error.message)
  end
end
