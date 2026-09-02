# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class NonRelocatableClonePathsTest < ActiveSupport::TestCase
  setup do
    @clone = Dir.mktmpdir("nrcp-clone")
    @adapter = RealFileSystemAdapter.new
  end

  teardown do
    FileUtils.remove_entry(@clone) if @clone && Dir.exist?(@clone)
  end

  # A virtualenv, as `python -m venv` / `uv venv` leave it: a marker at the root
  # and a console script whose shebang names the interpreter absolutely.
  def create_virtualenv(relative_path, home: @clone)
    venv = File.join(@clone, relative_path)
    FileUtils.mkdir_p(File.join(venv, "bin"))
    File.write(File.join(venv, "pyvenv.cfg"), <<~CFG)
      home = /usr/bin
      version = 3.13.1
      command = /usr/bin/python3 -m venv #{File.join(home, relative_path)}
    CFG
    File.write(File.join(venv, "bin", "pytest"), "#!#{File.join(home, relative_path, 'bin', 'python')}\n")
    venv
  end

  test "finds a virtualenv at the clone root" do
    create_virtualenv(".venv")

    assert_equal [ ".venv" ], NonRelocatableClonePaths.detect(@clone, file_system: @adapter)
  end

  test "finds virtualenvs nested under the clone, hidden or not" do
    create_virtualenv(".venv")
    create_virtualenv("packages/api/.venv")
    create_virtualenv("tools/env")

    assert_equal [ ".venv", "packages/api/.venv", "tools/env" ],
      NonRelocatableClonePaths.detect(@clone, file_system: @adapter)
  end

  test "a directory merely named venv is not a virtualenv" do
    FileUtils.mkdir_p(File.join(@clone, "venv"))
    File.write(File.join(@clone, "venv", "README.md"), "a source directory that happens to be called venv")

    assert_empty NonRelocatableClonePaths.detect(@clone, file_system: @adapter)
  end

  # The one result that would prune the whole copy. A `pyvenv.cfg` written
  # directly into the clone root names the root itself, and "" as an exclusion
  # pattern must never come back.
  test "never names the clone root itself" do
    File.write(File.join(@clone, "pyvenv.cfg"), "home = /usr/bin\n")

    assert_empty NonRelocatableClonePaths.detect(@clone, file_system: @adapter)
  end

  test "a clone path that does not exist yields nothing" do
    assert_empty NonRelocatableClonePaths.detect(File.join(@clone, "gone"), file_system: @adapter)
    assert_empty NonRelocatableClonePaths.detect(nil, file_system: @adapter)
  end

  test "a scan that raises is reported and treated as nothing to exclude" do
    failing = Class.new(RealFileSystemAdapter) do
      def glob(*, **) = raise(Errno::EACCES, "nope")
    end.new

    assert_empty NonRelocatableClonePaths.detect(@clone, file_system: failing)
  end

  test "to_patterns matches the detected path literally, metacharacters and all" do
    create_virtualenv("pkg[1]/.venv")

    detected = NonRelocatableClonePaths.detect(@clone, file_system: @adapter)
    assert_equal [ "pkg[1]/.venv" ], detected

    pattern = NonRelocatableClonePaths.to_patterns(detected).sole
    assert File.fnmatch?(pattern, "pkg[1]/.venv", File::FNM_PATHNAME | File::FNM_DOTMATCH),
      "the escaped pattern must still match the path it came from"
    assert_not File.fnmatch?(pattern, "pkg1/.venv", File::FNM_PATHNAME | File::FNM_DOTMATCH),
      "an unescaped bracket would turn the path into a character class"
  end

  test "the patterns prune exactly the virtualenv out of a real copy" do
    create_virtualenv(".venv")
    FileUtils.mkdir_p(File.join(@clone, "src"))
    File.write(File.join(@clone, "src", "app.py"), "print('hi')")

    destination = File.join(Dir.mktmpdir("nrcp-dest"), "clone")
    patterns = NonRelocatableClonePaths.to_patterns(
      NonRelocatableClonePaths.detect(@clone, file_system: @adapter)
    )
    @adapter.cp_r(@clone, destination, exclude: patterns)

    assert File.exist?(File.join(destination, "src", "app.py")), "the working tree still comes along"
    assert_not File.exist?(File.join(destination, ".venv")), "the virtualenv does not"

    # The safety property the relocation path depends on: detection reads, the
    # copy writes elsewhere, and the source a live session may be running in is
    # left exactly as it was.
    assert File.exist?(File.join(@clone, ".venv", "bin", "pytest")),
      "the source clone must survive the copy untouched"
  ensure
    FileUtils.remove_entry(File.dirname(destination)) if destination && Dir.exist?(File.dirname(destination))
  end
end
