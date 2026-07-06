# frozen_string_literal: true

# Base interface for file system operations
# Provides a testable abstraction over Ruby's File, Dir, and FileUtils
#
# Usage:
#   adapter = RealFileSystemAdapter.new
#   content = adapter.read("/path/to/file")
#   adapter.write("/path/to/file", "new content")
#
# For testing:
#   adapter = MockFileSystemAdapter.new
#   adapter.write("/fake/path", "test data")
#   adapter.read("/fake/path") # => "test data"
#
# Note: This adapter only abstracts I/O operations (read, write, exists?, etc.).
# Pure path utilities (File.join, File.basename, File.expand_path, File.dirname)
# remain as direct calls since they don't interact with the file system.
class FileSystemAdapter
  # Read the entire contents of a file
  # @param path [String] The file path to read
  # @return [String] The file contents
  # @raise [Errno::ENOENT] If the file does not exist
  def read(path)
    raise NotImplementedError, "#{self.class}#read must be implemented"
  end

  # Write content to a file
  # @param path [String] The file path to write to
  # @param content [String] The content to write
  # @param options [Hash] Additional options (e.g., mode:, encoding:)
  # @return [Integer] The number of bytes written
  def write(path, content, **options)
    raise NotImplementedError, "#{self.class}#write must be implemented"
  end

  # Check if a file or directory exists
  # @param path [String] The path to check
  # @return [Boolean] True if the path exists
  def exists?(path)
    raise NotImplementedError, "#{self.class}#exists? must be implemented"
  end

  # Check if a path is a directory
  # @param path [String] The path to check
  # @return [Boolean] True if the path is a directory
  def directory?(path)
    raise NotImplementedError, "#{self.class}#directory? must be implemented"
  end

  # Find files matching a pattern
  # @param pattern [String] A glob pattern (e.g., "*.rb", "**/*.txt")
  # @return [Array<String>] List of matching file paths
  def glob(pattern)
    raise NotImplementedError, "#{self.class}#glob must be implemented"
  end

  # Get the modification time of a file
  # @param path [String] The file path
  # @return [Time] The last modification time
  # @raise [Errno::ENOENT] If the file does not exist
  def mtime(path)
    raise NotImplementedError, "#{self.class}#mtime must be implemented"
  end

  # Create a directory and all parent directories
  # @param path [String] The directory path to create
  # @return [Array<String>] List of created directories
  def mkdir_p(path)
    raise NotImplementedError, "#{self.class}#mkdir_p must be implemented"
  end

  # Remove a file or directory recursively
  # @param path [String] The path to remove
  # @return [void]
  def rm_rf(path)
    raise NotImplementedError, "#{self.class}#rm_rf must be implemented"
  end

  # Change file permissions
  # @param mode [Integer] The file mode (e.g., 0o755)
  # @param path [String] The file path
  # @return [Integer] Zero (success)
  def chmod(mode, path)
    raise NotImplementedError, "#{self.class}#chmod must be implemented"
  end

  # Check if a file or directory is readable
  # @param path [String] The path to check
  # @return [Boolean] True if the path is readable
  def readable?(path)
    raise NotImplementedError, "#{self.class}#readable? must be implemented"
  end

  # Copy a file or directory recursively
  # @param src [String] The source path
  # @param dest [String] The destination path
  # @return [void]
  def cp_r(src, dest)
    raise NotImplementedError, "#{self.class}#cp_r must be implemented"
  end

  # Write binary content to a file
  # @param path [String] The file path to write to
  # @param content [String] The binary content to write
  # @return [Integer] The number of bytes written
  def binwrite(path, content)
    raise NotImplementedError, "#{self.class}#binwrite must be implemented"
  end

  # Read binary content from a file
  # @param path [String] The file path to read
  # @return [String] The binary file contents (ASCII-8BIT encoding)
  def binread(path)
    raise NotImplementedError, "#{self.class}#binread must be implemented"
  end
end
