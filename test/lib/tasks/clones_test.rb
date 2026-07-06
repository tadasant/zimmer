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
end
