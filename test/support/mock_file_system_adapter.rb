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

  # The mock holds a flat set of paths rather than a tree, so a directory's
  # immediate entries are derived: every path under it, reduced to its first
  # remaining segment.
  def children(path)
    raise Errno::ENOTDIR, "Not a directory - #{path}" unless @directories.include?(path)

    prefix = "#{path}/"
    (@files.keys + @directories.to_a)
      .select { |candidate| candidate.start_with?(prefix) }
      .map { |candidate| candidate.delete_prefix(prefix).split("/").first }
      .compact.uniq.sort
  end

  # The mock has no symlinks to model.
  def symlink?(_path)
    false
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

  def rename(src, dest)
    raise Errno::ENOENT, "No such file or directory - #{src}" unless exists?(src)
    raise Errno::EEXIST, "File exists - #{dest}" if exists?(dest)

    move = ->(from, to) do
      @files[to] = @files.delete(from) if @files.key?(from)
      @directories.add(to) && @directories.delete(from) if @directories.include?(from)
      @mtimes[to] = @mtimes.delete(from) if @mtimes.key?(from)
    end

    descendants = (@files.keys + @directories.to_a).select { |p| p.start_with?("#{src}/") }
    move.call(src, dest)
    descendants.each { |p| move.call(p, "#{dest}#{p[src.length..]}") }

    0
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
  # In the mock, we copy all files and directories that start with src path.
  # `exclude` holds fnmatch patterns against the path relative to src, matching
  # RealFileSystemAdapter's pruning.
  def cp_r(src, dest, exclude: [])
    # Copy the directory itself
    if @directories.include?(src)
      @directories.add(dest)
    end

    # Copy all files under src to dest
    @files.keys.select { |p| p.start_with?("#{src}/") || p == src }.each do |src_file|
      next if excluded?(src, src_file, exclude)

      dest_file = src_file.sub(src, dest)
      @files[dest_file] = @files[src_file]
      @mtimes[dest_file] = @mtimes[src_file] if @mtimes[src_file]
    end

    # Copy all directories under src to dest
    @directories.select { |d| d.start_with?("#{src}/") }.each do |src_dir|
      next if excluded?(src, src_dir, exclude)

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

  # Iterate a file's lines (the mock holds contents in memory, so there is
  # nothing to stream — the interface is what matters)
  def each_line(path, &block)
    read(path).each_line(&block)
  end

  private

  # The real adapter prunes at descent, so an excluded directory takes its whole
  # subtree with it. The mock walks a flat path list instead, so it has to test
  # every ancestor of the path as well as the path itself.
  def excluded?(src, path, patterns)
    return false if patterns.blank?
    # The copy root itself has no path relative to itself to match against.
    return false if path == src

    relative = path.delete_prefix("#{src}/")
    components = relative.split("/")

    components.each_index.any? do |i|
      candidate = components[0..i].join("/")
      patterns.any? { |pattern| File.fnmatch?(pattern, candidate, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
    end
  end
end
