# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_file_system_adapter"
require_relative "../support/mock_claude_cli_adapter"

# A router session's fresh start takes a warm process when WarmProcessPool has
# one: it adopts the process's clone and Claude session id, hands it the prompt
# where a cold start would spawn, and monitors it like any other turn. Every
# refusal falls back to an ordinary spawn in the same clone. WarmProcessPoolTest
# covers the claim, the delivery protocol and the refill against real processes.
class AgentSessionJobWarmProcessTest < ActiveJob::TestCase
  CLONE_PATH = "/tmp/warm-process-job-test-clone"
  WARM_PID = 4242
  WARM_SESSION_ID = "0b6f7a5e-1d2c-4c39-9a51-7b8f0f2f6e11"

  setup do
    @session = Session.create!(
      prompt: "Route this request",
      agent_runtime: "claude_code",
      status: :waiting,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      metadata: { "agent_root_key" => "zimmer-orchestrator" },
      # A turn that wrote a conversation, so its clean exit is a finished turn
      # rather than one to retry.
      transcript: { "type" => "user", "message" => { "content" => "Route this request" } }.to_json
    )
    @entry = stub(
      "warm entry",
      pid: WARM_PID,
      clone_path: CLONE_PATH,
      working_directory: CLONE_PATH,
      subdirectory: nil,
      claude_session_id: WARM_SESSION_ID,
      stderr_log_path: "#{CLONE_PATH}/claude_stderr.log",
      age_seconds: 30,
      timings: { "initialize" => 40 },
      delivered?: false
    )
    TranscriptPollerService.stubs(:new).returns(stub(poll_and_broadcast: nil))
  end

  test "a claimed warm process takes the first prompt and is monitored as the turn; nothing is spawned" do
    WarmProcessPool.expects(:claim).with(@session).returns(@entry)
    WarmProcessPool.expects(:adopt_directories!).with(@entry, instance_of(Session))
    delivered = nil
    WarmProcessPool.expects(:deliver!).with { |entry, **kwargs| entry == @entry && (delivered = kwargs) }
    WarmProcessPool.expects(:finish!).with(@entry, session: instance_of(Session))
    GitCloneService.expects(:create_clone).never

    job = run_turn

    assert_empty job.cli_adapter.executed_commands, "the warm process is the turn's process"
    @session.reload
    assert_equal WARM_SESSION_ID, @session.session_id, "the session takes the id the process booted with"
    assert_equal CLONE_PATH, @session.metadata["clone_path"]
    assert_equal WARM_PID, @session.metadata["process_pid"]
    assert_equal true, @session.metadata["runtime_started"]
    assert_equal "needs_input", @session.status

    message = JSON.parse(delivered[:message_json])
    assert_equal "user", message["type"]
    assert message.dig("message", "content", 0, "text").start_with?("Route this request"),
      "the session's own prompt is what the process is handed"
    assert_includes delivered[:append_system_prompt], "Session ID: #{@session.id}"
    assert_includes all_log_content, "Handed the prompt to warm router process #{WARM_PID}"
  end

  test "a delivery the process refuses falls back to a cold spawn in the same clone, under the same id" do
    WarmProcessPool.stubs(:claim).returns(@entry)
    WarmProcessPool.stubs(:adopt_directories!)
    WarmProcessPool.expects(:deliver!).raises(WarmProcessPool::Entry::Mismatch, "workspace_changed")
    WarmProcessPool.expects(:abandon!).with(@entry, session: instance_of(Session), reason: "workspace_changed")

    job = run_turn

    assert_equal 1, job.cli_adapter.executed_commands.size
    spawned = job.cli_adapter.executed_commands.first
    assert_equal WARM_SESSION_ID, spawned[:session_id]
    assert_equal CLONE_PATH, spawned[:working_dir]
    assert_includes all_log_content, "could not take this session (workspace_changed"
  end

  test "directories that cannot move give the process up before anything else is written" do
    WarmProcessPool.stubs(:claim).returns(@entry)
    WarmProcessPool.expects(:adopt_directories!).raises(WarmProcessPool::Entry::Mismatch, "session_config_dir_exists")
    WarmProcessPool.expects(:abandon!).with(@entry, session: instance_of(Session), reason: "session_config_dir_exists")
    WarmProcessPool.expects(:deliver!).never

    job = run_turn

    assert_equal 1, job.cli_adapter.executed_commands.size
  end

  test "with no warm process the session clones and spawns as before" do
    WarmProcessPool.expects(:claim).returns(nil)
    GitCloneService.expects(:create_clone).returns(clone_result)
    WarmProcessPool.expects(:deliver!).never

    job = run_turn

    assert_equal 1, job.cli_adapter.executed_commands.size
    assert_not_equal WARM_SESSION_ID, @session.reload.session_id
  end

  test "a claimed process the turn never reaches is abandoned on the way out" do
    WarmProcessPool.stubs(:claim).returns(@entry)
    WarmProcessPool.stubs(:adopt_directories!)
    AgentSessionJob.any_instance.stubs(:gate_and_inject_oauth!).returns(true)
    WarmProcessPool.expects(:deliver!).never
    WarmProcessPool.expects(:abandon!).with(@entry, session: instance_of(Session), reason: "not_started")

    run_turn
  end

  test "a clone-only start never takes a warm process" do
    WarmProcessPool.expects(:claim).never
    GitCloneService.expects(:create_clone).returns(clone_result)

    job = new_job
    job.perform(@session.id, nil, resume_monitoring: false, clone_only: true)
  end

  private

  def clone_result
    { clone_path: CLONE_PATH, working_directory: CLONE_PATH, subdirectory: nil, warm: false }
  end

  def new_job
    job = AgentSessionJob.new
    job.process_manager = MockProcessManager.new
    job.file_system = MockFileSystemAdapter.new
    job.cli_adapter = MockClaudeCliAdapter.new
    job.file_system.mkdir_p(CLONE_PATH)
    job.file_system.write("#{CLONE_PATH}/claude_stderr.log", "")
    job
  end

  # One fresh-start turn, start to finish: the process (warm or spawned) exits
  # cleanly on the third poll.
  def run_turn
    job = new_job
    polls = 0
    job.process_manager.wait_hook = lambda do |pid, flags|
      next [ pid, MockProcessManager::MockStatus.new(0) ] unless flags == Process::WNOHANG

      polls += 1
      polls > 2 ? [ pid, MockProcessManager::MockStatus.new(0) ] : nil
    end
    job.cli_adapter.execute_hook = ->(_opts) { { pid: 12_345, stderr_log_path: "#{CLONE_PATH}/claude_stderr.log" } }

    Thread.stub(:new, ->(&_block) { stub(alive?: false, kill: nil, join: nil) }) do
      job.perform(@session.id)
    end
    job
  end

  def all_log_content = @session.logs.reload.map(&:content).join("\n")
end
