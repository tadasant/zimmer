# frozen_string_literal: true

require "fileutils"

# Real implementation of FileSystemAdapter using Ruby's File, Dir, and FileUtils
# This adapter performs actual file system operations and is used in production.
#
# Usage:
#   adapter = RealFileSystemAdapter.new
#   adapter.write("/tmp/test.txt", "Hello World")
#   content = adapter.read("/tmp/test.txt") # => "Hello World"
class RealFileSystemAdapter < FileSystemAdapter
  def read(path)
    File.read(path)
  end

  def write(path, content, **options)
    File.write(path, content, **options)
  end

  def exists?(path)
    File.exist?(path)
  end

  def directory?(path)
    File.directory?(path)
  end

  def glob(pattern)
    Dir.glob(pattern)
  end

  def mtime(path)
    File.mtime(path)
  end

  def mkdir_p(path)
    FileUtils.mkdir_p(path)
  end

  def rm_rf(path)
    FileUtils.rm_rf(path)
  end

  def chmod(mode, path)
    File.chmod(mode, path)
  end

  def readable?(path)
    File.readable?(path)
  end

  def cp_r(src, dest)
    FileUtils.cp_r(src, dest)
  end

  def binwrite(path, content)
    File.binwrite(path, content)
  end

  def binread(path)
    File.binread(path)
  end
end
