# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_file_system_adapter"
require_relative "../support/mock_claude_cli_adapter"

# A fresh start the pool serves — a router session under the `router` scope, a
# session on any pooled key under `active` — asks GitCloneService for a warm
# clone, records whether it got one, and refills the pool; any other session
# clones exactly as before. WarmClonePoolTest covers the claim itself against
# real repositories, and which sessions the pool serves.
class AgentSessionJobWarmCloneTest < ActiveJob::TestCase
  CLONE_PATH = "/tmp/warm-clone-job-test-clone"
  REPO = "https://github.com/test/repo.git"

  setup do
    @previous_size = ENV["QUICK_ROUTER_WARM_CLONES"]
    ENV["QUICK_ROUTER_WARM_CLONES"] = "1"
    # What happens after the clone is not under test, and the clone path is a mock.
    AirPrepareService.any_instance.stubs(:prepare!)
    # Every session below is on this repository, and it is the router's: the
    # pool keeps it under either scope.
    WarmPoolPolicy.stubs(:targets).returns([
      WarmPoolPolicy::Target.new(repo_url: REPO, branch: "main", size: 1, roots: {}, starts: 0, score: 0.0)
    ])
  end

  teardown do
    ENV["QUICK_ROUTER_WARM_CLONES"] = @previous_size
  end

  test "a router session claims a warm clone, records it, and refills the pool" do
    session = create_session(agent_root_key: "zimmer-orchestrator")
    GitCloneService.expects(:create_clone).with(anything, has_entry(warm: true)).returns(clone_result(warm: true))

    assert_enqueued_with(job: WarmClonePoolReplenishJob) { run_clone_setup(session) }

    assert_equal "claimed", session.reload.metadata["warm_clone"]
    assert_includes all_log_content(session), "Claimed a pre-warmed clone from the pool"
  end

  test "a router session that finds the pool empty records the miss and still refills" do
    session = create_session(agent_root_key: "zimmer-router")
    GitCloneService.expects(:create_clone).with(anything, has_entry(warm: true)).returns(clone_result(warm: false))

    assert_enqueued_with(job: WarmClonePoolReplenishJob) { run_clone_setup(session) }

    assert_equal "missed", session.reload.metadata["warm_clone"]
    assert_includes all_log_content(session), "No pre-warmed clone was ready; cloned cold"
  end

  test "under the active scope, a session on any other root on a pooled key claims a warm clone" do
    AppSetting.editable.update!(warm_clone_pool_active_roots_enabled: true)
    session = create_session(agent_root_key: "zimmer")
    GitCloneService.expects(:create_clone).with(anything, has_entry(warm: true)).returns(clone_result(warm: true))

    assert_enqueued_with(job: WarmClonePoolReplenishJob) { run_clone_setup(session) }

    assert_equal "claimed", session.reload.metadata["warm_clone"]
  end

  test "under the active scope, a session that finds its key's pool empty records the miss" do
    AppSetting.editable.update!(warm_clone_pool_active_roots_enabled: true)
    session = create_session(agent_root_key: "zimmer")
    GitCloneService.expects(:create_clone).with(anything, has_entry(warm: true)).returns(clone_result(warm: false))

    run_clone_setup(session)

    assert_equal "missed", session.reload.metadata["warm_clone"]
  end

  test "under the router scope, a session on any other root never asks for a warm clone" do
    session = create_session(agent_root_key: "zimmer")
    GitCloneService.expects(:create_clone).with(anything, has_entry(warm: false)).returns(clone_result(warm: false))

    assert_no_enqueued_jobs(only: WarmClonePoolReplenishJob) { run_clone_setup(session) }

    assert_nil session.reload.metadata["warm_clone"]
  end

  test "with the pool turned off a router session clones cold and records nothing" do
    ENV["QUICK_ROUTER_WARM_CLONES"] = "0"
    session = create_session(agent_root_key: "zimmer-orchestrator")
    GitCloneService.expects(:create_clone).with(anything, has_entry(warm: false)).returns(clone_result(warm: false))

    assert_no_enqueued_jobs(only: WarmClonePoolReplenishJob) { run_clone_setup(session) }

    assert_nil session.reload.metadata["warm_clone"]
  end

  test "bookkeeping that fails never fails the session's start" do
    session = create_session(agent_root_key: "zimmer-orchestrator")
    GitCloneService.expects(:create_clone).with(anything, has_entry(warm: true)).returns(clone_result(warm: true))
    WarmClonePoolReplenishJob.stubs(:perform_later).raises(ActiveRecord::ConnectionNotEstablished)

    run_clone_setup(session)

    assert_not_equal "failed", session.reload.status
    assert_includes all_log_content(session), "Could not record the warm clone outcome"
  end

  private

  def create_session(agent_root_key:)
    Session.create!(
      prompt: nil,
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: REPO,
      branch: "main",
      metadata: { "agent_root_key" => agent_root_key }
    )
  end

  def clone_result(warm:)
    { clone_path: CLONE_PATH, working_directory: CLONE_PATH, subdirectory: nil, warm: warm }
  end

  # The real clone-setup block, with the filesystem, process manager and runtime
  # mocked out. `clone_only` is the shortest path through it that runs every line
  # of the setup without spending a turn.
  def run_clone_setup(session)
    job = AgentSessionJob.new
    job.process_manager = MockProcessManager.new
    job.file_system = MockFileSystemAdapter.new
    job.cli_adapter = MockClaudeCliAdapter.new
    job.file_system.mkdir_p(CLONE_PATH)

    job.perform(session.id, nil, resume_monitoring: false, clone_only: true)
  end

  def all_log_content(session) = session.logs.reload.map(&:content).join("\n")
end
