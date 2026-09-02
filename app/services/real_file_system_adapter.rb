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

  def children(path)
    Dir.children(path)
  end

  def symlink?(path)
    File.symlink?(path)
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

  def rename(src, dest)
    File.rename(src, dest)
  end

  def chmod(mode, path)
    File.chmod(mode, path)
  end

  def readable?(path)
    File.readable?(path)
  end

  def cp_r(src, dest, exclude: [])
    return FileUtils.cp_r(src, dest) if exclude.blank?

    copy_pruned(src, dest, exclude)
  end

  def binwrite(path, content)
    File.binwrite(path, content)
  end

  def binread(path)
    File.binread(path)
  end

  def each_line(path, &block)
    File.foreach(path, mode: "rb", &block)
  end

  private

  # FileUtils offers no filter hook, so a pruned copy walks the tree itself.
  # Entries are matched by their path relative to the copy root, which is what
  # lets "vendor/bundle" mean that one directory rather than every directory
  # named `bundle`.
  #
  # Modes ride along: FileUtils.copy_entry creates each file with the source's
  # mode, so an executable stays executable.
  def copy_pruned(src, dest, patterns, relative_prefix = nil)
    FileUtils.mkdir_p(dest)

    Dir.children(src).each do |name|
      relative = relative_prefix ? File.join(relative_prefix, name) : name
      next if patterns.any? { |pattern| File.fnmatch?(pattern, relative, File::FNM_PATHNAME | File::FNM_DOTMATCH) }

      from = File.join(src, name)
      to = File.join(dest, name)

      if File.directory?(from) && !File.symlink?(from)
        copy_pruned(from, to, patterns, relative)
      else
        # copy_entry keeps a symlink a symlink rather than following it.
        FileUtils.copy_entry(from, to)
      end
    end
  end
end
