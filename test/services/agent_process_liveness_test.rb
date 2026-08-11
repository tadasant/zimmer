require "test_helper"

# Covers the check that keeps a session to one live agent process (zimmer#395).
#
# The headline tests here spawn a REAL child process and let the service find and kill
# it, because that is the thing that was broken: a process outliving the job that spawned
# it, with nothing looking for it. The classification tests around them pin the two ways
# a pid check goes wrong when its provenance is not recorded — a foreign PID namespace
# and a recycled pid — since both directions are silent, and a wrong "alive" here means
# signalling a process that is not ours.
class AgentProcessLivenessTest < ActiveSupport::TestCase
  setup do
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid
    )
    @spawned_pids = []
  end

  teardown do
    @spawned_pids.each do |pid|
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end

  # A real, long-lived child standing in for an agent CLI process that outlived its job.
  def spawn_real_process
    pid = Process.spawn("sleep", "120", out: File::NULL, err: File::NULL)
    @spawned_pids << pid
    pid
  end

  def record(pid)
    @session.record_agent_process!(pid)
    @session.reload
  end

  def procfs?
    File.exist?("/proc/self/ns/pid")
  end

  def require_procfs
    skip("requires Linux /proc") unless procfs?
  end

  # === Identity capture ====================================================

  test "identity_for captures the pid, its namespace and its start time" do
    require_procfs
    pid = spawn_real_process

    identity = AgentProcessLiveness.identity_for(pid)

    assert_equal pid, identity["pid"]
    assert_equal File.readlink("/proc/self/ns/pid"), identity["pid_namespace"]
    assert_predicate identity["started_at_ticks"].to_s, :present?
  end

  test "identity_for returns nil without a pid" do
    assert_nil AgentProcessLiveness.identity_for(nil)
  end

  test "record_agent_process! writes the pid and its identity together" do
    require_procfs
    pid = spawn_real_process

    record(pid)

    assert_equal pid, @session.metadata["process_pid"]
    assert_equal pid, @session.metadata[AgentProcessLiveness::IDENTITY_KEY]["pid"]
  end

  # === Classification ======================================================

  test "status is :none when no process has ever been recorded" do
    assert_equal :none, AgentProcessLiveness.status(@session)
  end

  test "status is :alive for a process we spawned and recorded" do
    require_procfs
    record(spawn_real_process)

    assert_equal :alive, AgentProcessLiveness.status(@session)
  end

  test "status is :dead once the recorded process has exited" do
    require_procfs
    pid = spawn_real_process
    record(pid)

    Process.kill("KILL", pid)
    Process.wait(pid)

    assert_equal :dead, AgentProcessLiveness.status(@session)
  end

  test "status is :dead for an exited-but-unreaped process, which signal 0 would call alive" do
    require_procfs
    record(spawn_real_process)

    AgentProcessLiveness.stub(:zombie?, true) do
      assert_equal :dead, AgentProcessLiveness.status(@session)
    end
  end

  test "status is :recycled when the number is live but belongs to a different process" do
    require_procfs
    pid = spawn_real_process
    record(pid)

    # The process is still running under that pid; only its start time differs, which is
    # exactly what a recycled pid looks like: present, ours by number, not ours in fact.
    identity = @session.metadata[AgentProcessLiveness::IDENTITY_KEY].merge("started_at_ticks" => "1")
    @session.merge_metadata!(AgentProcessLiveness::IDENTITY_KEY => identity)

    assert_equal :recycled, AgentProcessLiveness.status(@session.reload)
  end

  test "status is :unknown for a pid recorded in a different PID namespace" do
    require_procfs
    record(spawn_real_process)

    identity = @session.metadata[AgentProcessLiveness::IDENTITY_KEY].merge("pid_namespace" => "pid:[999999999]")
    @session.merge_metadata!(AgentProcessLiveness::IDENTITY_KEY => identity)

    assert_equal :unknown, AgentProcessLiveness.status(@session.reload)
  end

  test "status is :unknown where /proc is unavailable" do
    require_procfs
    record(spawn_real_process)

    AgentProcessLiveness.stub(:pid_namespace, nil) do
      assert_equal :unknown, AgentProcessLiveness.status(@session)
    end
  end

  test "status is :unknown for an identity recorded before namespaces were captured" do
    @session.merge_metadata!(AgentProcessLiveness::IDENTITY_KEY => { "pid" => 4242 })

    assert_equal :unknown, AgentProcessLiveness.status(@session.reload)
  end

  # === The guard ===========================================================

  test "ensure_no_live_process! terminates an agent process that outlived its job" do
    # THE #395 REGRESSION, end to end against a real process: before this guard existed,
    # the next spawn simply overwrote process_pid and this process kept running — a second
    # agent on the same branch, the same scratch dir and the same conversation.
    require_procfs
    pid = spawn_real_process
    record(pid)
    log_buffer = LogBuffer.new(@session)

    state = AgentProcessLiveness.ensure_no_live_process!(
      @session,
      process_manager: SystemProcessManager.new,
      log_buffer: log_buffer
    )
    log_buffer.flush

    assert_equal :alive, state
    assert_equal :dead, AgentProcessLiveness.status(@session),
      "the orphaned agent process must be gone before a new one is spawned"
    assert @session.logs.reload.any? { |log| log.content.include?("Previous turn's agent process") },
      "the operator needs to see that a process was orphaned"
  end

  test "ensure_no_live_process! signals nothing when there is no recorded process" do
    manager = MockProcessManager.new

    assert_equal :none, AgentProcessLiveness.ensure_no_live_process!(@session, process_manager: manager)
    assert_empty manager.killed_processes
  end

  test "ensure_no_live_process! never signals a recycled pid" do
    # The failure JobLiveness warns about: a pid that is live but belongs to somebody
    # else. Killing it would take out an unrelated process on the host.
    require_procfs
    pid = spawn_real_process
    record(pid)
    identity = @session.metadata[AgentProcessLiveness::IDENTITY_KEY].merge("started_at_ticks" => "1")
    @session.merge_metadata!(AgentProcessLiveness::IDENTITY_KEY => identity)

    manager = MockProcessManager.new
    state = AgentProcessLiveness.ensure_no_live_process!(@session.reload, process_manager: manager)

    assert_equal :recycled, state
    assert_empty manager.killed_processes
    assert_nothing_raised { Process.kill(0, pid) }
  end

  test "ensure_no_live_process! never signals a pid from another PID namespace" do
    require_procfs
    record(spawn_real_process)
    identity = @session.metadata[AgentProcessLiveness::IDENTITY_KEY].merge("pid_namespace" => "pid:[999999999]")
    @session.merge_metadata!(AgentProcessLiveness::IDENTITY_KEY => identity)

    manager = MockProcessManager.new
    state = AgentProcessLiveness.ensure_no_live_process!(@session.reload, process_manager: manager)

    assert_equal :unknown, state
    assert_empty manager.killed_processes
  end

  test "ensure_no_live_process! swallows its own failures rather than blocking a spawn" do
    # The guard sits on the spawn path. A bug in it must never be why a session fails to
    # start — that would trade a rare double-run for a common dead session.
    AgentProcessLiveness.stub(:status, ->(_session) { raise "probe exploded" }) do
      assert_equal :error, AgentProcessLiveness.ensure_no_live_process!(@session)
    end
  end
end
