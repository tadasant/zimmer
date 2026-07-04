# frozen_string_literal: true

require "set"

# In-memory mock implementation of FileSystemAdapter for testing
# Provides a lightweight file system simulation without touching the actual disk.
#
# Usage in tests:
#   adapter = MockFileSystemAdapter.new
#   adapter.write("/fake/path.txt", "test data")
#   adapter.read("/fake/path.txt") # => "test data"
#   adapter.exists?("/fake/path.txt") # => true
#
# This allows tests to verify file operations without side effects.
class MockFileSystemAdapter < FileSystemAdapter
  attr_reader :files, :directories

  def initialize
    @files = {} # path => content
    @directories = Set.new
    @mtimes = {} # path => time
  end

  def read(path)
    raise Errno::ENOENT, "No such file or directory - #{path}" unless @files.key?(path)

    @files[path]
  end

  def write(path, content, **options)
    @files[path] = content
    @mtimes[path] = Time.current
    content.bytesize
  end

  def exists?(path)
    @files.key?(path) || @directories.include?(path)
  end

  def directory?(path)
    @directories.include?(path)
  end

  def glob(pattern)
    # Convert glob pattern to regex
    # ** matches any number of directories (including none)
    # * matches any characters except /
    # Need to escape dots first, but preserve glob patterns
    regex_pattern = pattern
      .gsub(".", "\\.")            # Escape literal dots first
      .gsub("**", "__DOUBLESTAR__") # Placeholder for **
      .gsub("*", "[^/]*")           # * matches any non-slash characters
      .gsub("__DOUBLESTAR__", ".*") # ** matches anything including slashes
      .gsub("?", ".")               # ? matches any single character

    regex = /^#{regex_pattern}$/

    # Search both files and directories to match real filesystem behavior
    matching_files = @files.keys.select { |path| path.match?(regex) }
    matching_dirs = @directories.select { |path| path.match?(regex) }

    (matching_files + matching_dirs.to_a).sort
  end

  def mtime(path)
    raise Errno::ENOENT, "No such file or directory - #{path}" unless exists?(path)

    @mtimes[path] || Time.current
  end

  def mkdir_p(path)
    @directories.add(path)
    # Also add parent directories
    parts = path.split("/")
    parts.each_with_index do |_, i|
      parent = parts[0..i].join("/")
      @directories.add(parent) unless parent.empty?
    end
    [ path ]
  end

  def rm_rf(path)
    @files.delete(path)
    @directories.delete(path)
    @mtimes.delete(path)

    # Also remove children
    @files.keys.select { |p| p.start_with?("#{path}/") }.each do |p|
      @files.delete(p)
      @mtimes.delete(p)
    end

    @directories.select { |d| d.start_with?("#{path}/") }.each do |d|
      @directories.delete(d)
    end
  end

  def chmod(mode, path)
    raise Errno::ENOENT, "No such file or directory - #{path}" unless exists?(path)

    # In the mock, we don't actually store file modes
    # Just verify the file exists and return success
    0
  end

  def readable?(path)
    # In the mock, all existing files/directories are readable
    exists?(path)
  end

  # Helper method for testing: reset all state
  def clear
    @files.clear
    @directories.clear
    @mtimes.clear
  end

  # Helper method for testing: set custom mtime for a file
  def set_mtime(path, time)
    @mtimes[path] = time
  end

  # Copy a file or directory recursively (simulated for testing)
  # In the mock, we copy all files and directories that start with src path
  def cp_r(src, dest)
    # Copy the directory itself
    if @directories.include?(src)
      @directories.add(dest)
    end

    # Copy all files under src to dest
    @files.keys.select { |p| p.start_with?("#{src}/") || p == src }.each do |src_file|
      dest_file = src_file.sub(src, dest)
      @files[dest_file] = @files[src_file]
      @mtimes[dest_file] = @mtimes[src_file] if @mtimes[src_file]
    end

    # Copy all directories under src to dest
    @directories.select { |d| d.start_with?("#{src}/") }.each do |src_dir|
      dest_dir = src_dir.sub(src, dest)
      @directories.add(dest_dir)
    end
  end

  # Write binary content to a file (same as write in mock - stores bytes as-is)
  def binwrite(path, content)
    write(path, content)
  end

  # Read binary content from a file (same as read in mock)
  def binread(path)
    read(path)
  end
end
