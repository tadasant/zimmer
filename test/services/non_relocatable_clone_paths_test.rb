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
  def create_virtualenv(relative_path, root: @clone)
    venv = File.join(root, relative_path)
    FileUtils.mkdir_p(File.join(venv, "bin"))
    File.write(File.join(venv, "pyvenv.cfg"), <<~CFG)
      home = /usr/bin
      version = 3.13.1
      command = /usr/bin/python3 -m venv #{venv}
    CFG
    File.write(File.join(venv, "bin", "pytest"), "#!#{File.join(venv, 'bin', 'python')}\n")
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

  # A repository that TRACKS a pyvenv.cfg as a fixture has nothing to relocate,
  # and dropping tracked files from the copy would read as a deletion to
  # CloneArtifactService. The script directory is what separates the two.
  test "a bare pyvenv.cfg with no script directory is a fixture, not an environment" do
    FileUtils.mkdir_p(File.join(@clone, "test/fixtures/env"))
    File.write(File.join(@clone, "test/fixtures/env/pyvenv.cfg"), "home = /usr/bin\n")

    assert_empty NonRelocatableClonePaths.detect(@clone, file_system: @adapter)
  end

  test "a Windows-layout virtualenv is found by its Scripts directory" do
    venv = File.join(@clone, ".venv")
    FileUtils.mkdir_p(File.join(venv, "Scripts"))
    File.write(File.join(venv, "pyvenv.cfg"), "home = C:\\Python313\n")

    assert_equal [ ".venv" ], NonRelocatableClonePaths.detect(@clone, file_system: @adapter)
  end

  # The one result that would prune the whole copy. A `pyvenv.cfg` written
  # directly into the clone root names the root itself, and "" as an exclusion
  # pattern must never come back.
  test "never names the clone root itself" do
    FileUtils.mkdir_p(File.join(@clone, "bin"))
    File.write(File.join(@clone, "pyvenv.cfg"), "home = /usr/bin\n")

    assert_empty NonRelocatableClonePaths.detect(@clone, file_system: @adapter)
  end

  test "stops descending at a virtualenv, so a nested marker is not reported twice" do
    venv = create_virtualenv(".venv")
    create_virtualenv("lib/python3.13/site-packages/vendored", root: venv)

    assert_equal [ ".venv" ], NonRelocatableClonePaths.detect(@clone, file_system: @adapter)
  end

  test "never descends into the history or dependency trees" do
    create_virtualenv(".git/hooks/.venv")
    create_virtualenv("node_modules/some-pkg/.venv")
    create_virtualenv("docs/node_modules/other-pkg/.venv")
    create_virtualenv("vendor/bundle/.venv")
    create_virtualenv("app/.venv")

    assert_equal [ "app/.venv" ], NonRelocatableClonePaths.detect(@clone, file_system: @adapter)
  end

  test "does not descend into what the caller is already excluding from the copy" do
    create_virtualenv("vendor/bundle/.venv")
    create_virtualenv("docs/deps/.venv")
    create_virtualenv("app/.venv")

    assert_equal [ "app/.venv" ],
      NonRelocatableClonePaths.detect(@clone, file_system: @adapter, prune: [ "vendor/bundle", "**/deps" ])
  end

  # The copy hands a symlink to FileUtils.copy_entry, which copies the link
  # rather than the tree behind it — so a venv reached only through one is not
  # this scan's business, and refusing to follow makes a symlink loop impossible.
  test "does not follow symlinked directories" do
    create_virtualenv("real/.venv")
    File.symlink(File.join(@clone, "real"), File.join(@clone, "linked"))
    File.symlink(@clone, File.join(@clone, "loop"))

    assert_equal [ "real/.venv" ], NonRelocatableClonePaths.detect(@clone, file_system: @adapter)
  end

  test "a clone path that does not exist yields nothing" do
    assert_empty NonRelocatableClonePaths.detect(File.join(@clone, "gone"), file_system: @adapter)
    assert_empty NonRelocatableClonePaths.detect(nil, file_system: @adapter)
  end

  # A tree that cannot be read is copied whole — the pre-fix behaviour — but the
  # operator has to be able to see that it happened.
  test "an unreadable tree is reported through the caller's logger" do
    failing = Class.new(RealFileSystemAdapter) do
      def children(path) = raise(Errno::EACCES, path)
    end.new
    logged = []
    logger = Struct.new(:sink) { def warn(message) = sink << message }.new(logged)

    assert_empty NonRelocatableClonePaths.detect(@clone, file_system: failing, logger: logger)
    assert_equal 1, logged.size
    assert_match(/Could not scan #{Regexp.escape(@clone)}/, logged.sole)
  end

  # Narrow on purpose: swallowing a programming error would silently restore the
  # exact staleness this class exists to prevent.
  test "a programming error is not swallowed" do
    broken = Class.new(RealFileSystemAdapter) do
      def children(path) = raise(NoMethodError, "undefined method")
    end.new

    assert_raises(NoMethodError) { NonRelocatableClonePaths.detect(@clone, file_system: broken) }
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

  # A clone base an operator chose, or a repository name derived from a
  # user-supplied git_root, can carry a metacharacter. The walk never builds a
  # pattern out of the root, so detection is unaffected by what it contains.
  test "a clone root containing glob metacharacters is scanned normally" do
    metaroot = File.join(@clone, "clone[1]")
    create_virtualenv(".venv", root: metaroot)

    assert_equal [ ".venv" ], NonRelocatableClonePaths.detect(metaroot, file_system: @adapter)
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

  # The mock the fork tests drive has to prune the same paths the real adapter
  # does, or those tests would prove nothing about production.
  test "the mock adapter agrees with the real one about an escaped pattern" do
    mock = MockFileSystemAdapter.new
    mock.write("/clone/pkg[1]/.venv/pyvenv.cfg", "home = /usr/bin")
    mock.write("/clone/pkg[1]/.venv/bin/pytest", "#!/clone/pkg[1]/.venv/bin/python")
    mock.write("/clone/pkg[1]/main.py", "print('hi')")
    mock.mkdir_p("/clone/pkg[1]/.venv/bin")

    detected = NonRelocatableClonePaths.detect("/clone", file_system: mock)
    assert_equal [ "pkg[1]/.venv" ], detected

    mock.cp_r("/clone", "/fork", exclude: NonRelocatableClonePaths.to_patterns(detected))

    assert mock.exists?("/fork/pkg[1]/main.py")
    assert_not mock.exists?("/fork/pkg[1]/.venv/bin/pytest")
  end
end
