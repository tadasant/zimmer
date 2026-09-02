# frozen_string_literal: true

require "test_helper"
require "rake"
require "tmpdir"
require "fileutils"

class ClonesTasksTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?

    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Session.destroy_all

    @src_base = Dir.mktmpdir("clones-src")
    @dest_base = Dir.mktmpdir("clones-dest")
  end

  teardown do
    Rake::Task.clear
    %w[DEST DRY_RUN REMOVE_OLD].each { |k| ENV.delete(k) }
    FileUtils.remove_entry(@src_base) if @src_base && Dir.exist?(@src_base)
    FileUtils.remove_entry(@dest_base) if @dest_base && Dir.exist?(@dest_base)
  end

  # Create a session whose clone lives on disk under @src_base.
  def session_with_clone(name:, status: "needs_input", working_subdir: nil)
    clone_path = File.join(@src_base, name)
    FileUtils.mkdir_p(clone_path)
    File.write(File.join(clone_path, "SENTINEL.txt"), "in progress")

    meta = { "clone_path" => clone_path }
    meta["working_directory"] = File.join(clone_path, working_subdir) if working_subdir

    Session.create!(
      prompt: "Test",
      status: status,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      metadata: meta
    )
  end

  def run_relocate
    capture_io { Rake::Task["clones:relocate"].execute }.first
  end

  test "dry run copies nothing and leaves metadata untouched" do
    session = session_with_clone(name: "repo-main-100-aaa")
    ENV["DEST"] = @dest_base
    ENV["DRY_RUN"] = "true"

    output = run_relocate

    assert_match(/DRY_RUN/, output)
    assert_equal [], Dir.children(@dest_base), "dry run must not copy any clone"
    assert_equal File.join(@src_base, "repo-main-100-aaa"), session.reload.metadata["clone_path"]
  end

  test "relocates the clone directory and rewrites all path-bearing metadata keys" do
    session = session_with_clone(name: "repo-main-101-bbb", working_subdir: "agents/agent-orchestrator")
    ENV["DEST"] = @dest_base

    run_relocate

    new_clone_path = File.join(@dest_base, "repo-main-101-bbb")
    assert Dir.exist?(new_clone_path), "clone should be copied to the destination base"
    assert File.exist?(File.join(new_clone_path, "SENTINEL.txt")), "clone contents should be copied"

    session.reload
    assert_equal new_clone_path, session.metadata["clone_path"]
    assert_equal File.join(new_clone_path, "agents/agent-orchestrator"), session.metadata["working_directory"]

    # Copy, never move: the source is left intact unless REMOVE_OLD is set.
    assert Dir.exist?(File.join(@src_base, "repo-main-101-bbb"))
  end

  test "is idempotent — a second run is a no-op once metadata points at the destination" do
    session = session_with_clone(name: "repo-main-102-ccc")
    ENV["DEST"] = @dest_base

    run_relocate
    relocated_path = session.reload.metadata["clone_path"]

    # Second run: clone_path now lives under dest_base, so it is skipped.
    output = run_relocate
    assert_match(/skipped\(already at dest\)=1/, output)
    assert_equal relocated_path, session.reload.metadata["clone_path"]
  end

  test "DEST equal to the current base is a whole no-op" do
    session = session_with_clone(name: "repo-main-103-ddd")
    ENV["DEST"] = @src_base

    output = run_relocate

    assert_match(/skipped\(already at dest\)=1/, output)
    assert_equal File.join(@src_base, "repo-main-103-ddd"), session.reload.metadata["clone_path"]
  end

  test "REMOVE_OLD reclaims the old dir for terminal sessions but never for live ones" do
    archived = session_with_clone(name: "repo-main-104-eee", status: "archived")
    live = session_with_clone(name: "repo-main-105-fff", status: "needs_input")
    ENV["DEST"] = @dest_base
    ENV["REMOVE_OLD"] = "true"

    run_relocate

    refute Dir.exist?(File.join(@src_base, "repo-main-104-eee")), "archived session's old clone should be removed"
    assert Dir.exist?(File.join(@src_base, "repo-main-105-fff")), "live (needs_input) session's old clone must survive"

    assert_equal File.join(@dest_base, "repo-main-104-eee"), archived.reload.metadata["clone_path"]
    assert_equal File.join(@dest_base, "repo-main-105-fff"), live.reload.metadata["clone_path"]
  end

  test "rewrites metadata even when the stored clone_path is non-canonical" do
    clone_path = File.join(@src_base, "repo-main-106-ggg")
    FileUtils.mkdir_p(clone_path)
    # Store a non-canonical value (trailing slash + redundant dot segment).
    noncanonical = File.join(@src_base, ".", "repo-main-106-ggg") + "/"
    session = Session.create!(
      prompt: "Test",
      status: "needs_input",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      metadata: { "clone_path" => noncanonical }
    )
    ENV["DEST"] = @dest_base

    run_relocate

    assert_equal File.join(@dest_base, "repo-main-106-ggg"), session.reload.metadata["clone_path"]
  end

  # --- Non-relocatable directories (zimmer#671) ------------------------------

  # A virtualenv as `uv venv` leaves it: the console scripts name the
  # interpreter by absolute path, so a copy of the tree arrives pointing back at
  # the clone it came from.
  def create_virtualenv(clone_path, relative_path: ".venv")
    venv = File.join(clone_path, relative_path)
    FileUtils.mkdir_p(File.join(venv, "bin"))
    File.write(File.join(venv, "pyvenv.cfg"), "home = /usr/bin\nversion = 3.13.1\n")
    File.write(File.join(venv, "bin", "pytest"), "#!#{File.join(venv, 'bin', 'python')}\nimport pytest\n")

    FileUtils.mkdir_p(File.join(clone_path, "src"))
    File.write(File.join(clone_path, "src", "app.py"), "print('hi')")
    venv
  end

  test "a relocated clone does not inherit the old clone's virtualenv" do
    session = session_with_clone(name: "repo-main-107-hhh")
    old_clone = session.metadata["clone_path"]
    create_virtualenv(old_clone)
    ENV["DEST"] = @dest_base

    output = run_relocate

    new_clone = File.join(@dest_base, "repo-main-107-hhh")
    assert_equal new_clone, session.reload.metadata["clone_path"]
    assert File.exist?(File.join(new_clone, "src", "app.py")), "the working tree still comes along"

    # The defect: before the fix this file existed in the new clone and opened
    # with `#!<OLD-CLONE>/.venv/bin/python`, so `uv run pytest` ran the previous
    # checkout's sources without saying so.
    assert_not File.exist?(File.join(new_clone, ".venv")),
      "a relocated clone must not carry a virtualenv whose shebangs name the clone it came from"

    assert_match(/leaving 1 non-relocatable path\(s\) out of the copy \(\.venv\)/, output)
  end

  # The property the whole remedy rests on: this task copies live sessions'
  # clones by design, so the exclusion must only ever shape what is WRITTEN to
  # the destination. Nothing is removed from the source.
  test "excluding a virtualenv never touches the source clone" do
    session = session_with_clone(name: "repo-main-108-iii")
    old_clone = session.metadata["clone_path"]
    venv = create_virtualenv(old_clone)
    shebang = File.readlines(File.join(venv, "bin", "pytest")).first
    ENV["DEST"] = @dest_base

    run_relocate

    assert File.exist?(File.join(venv, "pyvenv.cfg")), "the live session's venv must survive the copy"
    assert_equal shebang, File.readlines(File.join(venv, "bin", "pytest")).first,
      "the source clone is read, never rewritten or pruned"
    assert File.exist?(File.join(old_clone, "SENTINEL.txt"))
  end

  test "nested virtualenvs are found and named in the dry-run report" do
    session = session_with_clone(name: "repo-main-109-jjj")
    old_clone = session.metadata["clone_path"]
    create_virtualenv(old_clone)
    create_virtualenv(old_clone, relative_path: "packages/api/.venv")
    ENV["DEST"] = @dest_base
    ENV["DRY_RUN"] = "true"

    output = run_relocate

    assert_match(/leaving 2 non-relocatable path\(s\)/, output)
    assert_match(/\.venv, packages\/api\/\.venv/, output)
    assert_equal [], Dir.children(@dest_base), "a dry run still copies nothing"
    assert_equal old_clone, session.reload.metadata["clone_path"]
  end
end
