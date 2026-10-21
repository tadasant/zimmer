# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# The post-deploy task that guards the clones already on disk (#1382).
class GuardInjectedFilesInExistingClonesTest < ActiveSupport::TestCase
  setup do
    @entry = PostDeployTask::Registry.find("20261020031734")
    assert @entry
    @task_class = @entry.task_class
    @clones = Dir.mktmpdir("guard-existing-clones")
  end

  teardown do
    FileUtils.rm_rf(@clones)
  end

  def clone_session(git: true)
    dir = File.join(@clones, SecureRandom.hex(4))
    FileUtils.mkdir_p(dir)
    if git
      run_git(dir, "init", "-q", "-b", "main")
      File.write(File.join(dir, ".mcp.json"), "{}")
    end
    Session.create!(
      prompt: "p", agent_runtime: "claude_code", status: :needs_input,
      git_root: "https://github.com/test/repo.git", branch: "main",
      metadata: { "clone_path" => dir, "working_directory" => dir }
    )
  end

  def run_task
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    @task_class.new(run: run).up
    run.reload
  end

  def run_git(dir, *args)
    stdout, stderr, status = Open3.capture3("git", "-C", dir, *args)
    assert status.success?, "git #{args.join(' ')} failed: #{stderr}"
    stdout
  end

  test "guards an existing clone so its injected .mcp.json no longer shows to git" do
    session = clone_session
    assert_includes run_git(session.working_directory, "status", "--porcelain"), ".mcp.json"

    run = run_task

    assert_equal "", run_git(session.working_directory, "status", "--porcelain")
    assert_equal 1, run.stats["guarded"]
    assert_equal 0, run.stats["failed"]
  end

  test "a second pass changes nothing" do
    session = clone_session
    run = run_task
    exclude = File.join(session.working_directory, ".git", "info", "exclude")
    first = File.read(exclude)

    # A fresh cursor, or the sweep would start past this row and prove nothing.
    run.update!(cursor: {})
    @task_class.new(run: run).up

    assert_equal first, File.read(exclude)
  end

  test "counts a recorded clone that is gone, or is not a repository, and carries on" do
    # Fixture sessions can record a clone_path that is not on disk; they are
    # counted the same way, so measure against them rather than from zero.
    already = Session.where("metadata ->> 'clone_path' IS NOT NULL").count
    gone = clone_session(git: false)
    FileUtils.rm_rf(gone.working_directory)
    clone_session(git: false)
    kept = clone_session

    run = run_task

    assert_equal already + 2, run.stats["not_a_clone"]
    assert_equal 1, run.stats["guarded"]
    assert_equal "", run_git(kept.working_directory, "status", "--porcelain")
  end

  test "one clone that cannot be guarded does not stop the rest" do
    broken = clone_session
    info = File.join(broken.working_directory, ".git", "info")
    FileUtils.rm_rf(info)
    File.write(info, "not a directory")
    kept = clone_session

    run = run_task

    assert_equal 1, run.stats["failed"]
    assert_equal [ broken.id ], run.stats["failed_session_ids"]
    assert_equal "", run_git(kept.working_directory, "status", "--porcelain")
  end
end
