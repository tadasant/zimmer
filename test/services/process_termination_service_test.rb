require "test_helper"
require "mocha/minitest"
require "tempfile"

class ProcessTerminationServiceTest < ActiveSupport::TestCase
  setup do
    @mock_process_manager = MockProcessManager.new
  end

  # Make the mock's `wait` agree with its own liveness model.
  #
  # MockProcessManager#wait defaults to "the child has exited" no matter what the
  # same mock says about liveness. That is fine for tests that only need a status
  # back, but ProcessTerminationService now asks `wait` whether our child is still
  # alive (#280) — so any test that models a process as STILL RUNNING has to say so
  # on both channels, or the mock contradicts itself. WNOHANG on a live child
  # returns nil; once it is gone, the status is there to collect.
  def model_liveness_faithfully(manager)
    manager.wait_hook = ->(check_pid, _flags) do
      manager.running?(check_pid) ? nil : [ check_pid, MockProcessManager::MockStatus.new(0) ]
    end
  end

  # === Helpers for the real-process tests ===

  # Poll until the block is truthy or the timeout expires. Returns the result.
  def wait_until(timeout, interval: 0.05)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result
      return result if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep interval
    end
  end

  # The `ps` STAT field for a pid, or "" when the pid is not in the process table.
  def real_process_state(pid)
    return "" unless pid.to_i.positive?

    `ps -o stat= -p #{pid.to_i} 2>/dev/null`.strip
  end

  # A zombie is not alive: it is an exit status nobody has collected yet. Treating
  # it as alive is precisely the mistake #280 is about.
  def real_process_alive?(pid)
    state = real_process_state(pid)
    state.present? && !state.include?("Z")
  end

  # Best-effort teardown so a failed assertion cannot leak a 60s sleeper.
  def force_cleanup(pid)
    return unless pid.to_i.positive?

    [ -pid.to_i, pid.to_i ].each do |target|
      Process.kill("KILL", target)
    rescue SystemCallError
      nil
    end
    Process.wait2(pid.to_i, Process::WNOHANG)
  rescue SystemCallError
    nil
  end

  # Helper to create a service with process_info stubbed to show process exists
  def create_service_with_existing_process(pid:, process_manager:, **options)
    service = ProcessTerminationService.new(
      process_pid: pid,
      process_manager: process_manager,
      **options
    )
    # Stub process_info to report process exists and is owned by us
    service.define_singleton_method(:process_info) do
      { exists: true, is_zombie: false, owned_by_us: true, uid: Process.uid, state: "S" }
    end
    service
  end

  # === Tests for TerminationResult struct ===

  test "TerminationResult success? returns true for terminated status" do
    result = ProcessTerminationService::TerminationResult.new(status: :terminated, message: "test")
    assert result.success?
  end

  test "TerminationResult success? returns true for already_dead status" do
    result = ProcessTerminationService::TerminationResult.new(status: :already_dead, message: "test")
    assert result.success?
  end

  test "TerminationResult success? returns true for zombie_reaped status" do
    result = ProcessTerminationService::TerminationResult.new(status: :zombie_reaped, message: "test")
    assert result.success?
  end

  test "TerminationResult success? returns false for permission_denied status" do
    result = ProcessTerminationService::TerminationResult.new(status: :permission_denied, message: "test")
    assert_not result.success?
  end

  test "TerminationResult success? returns false for error status" do
    result = ProcessTerminationService::TerminationResult.new(status: :error, message: "test")
    assert_not result.success?
  end

  # === Tests for terminate method ===

  test "terminate returns structured result with status and message" do
    pid = @mock_process_manager.spawn("test-command")

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    result = service.terminate

    assert_instance_of ProcessTerminationService::TerminationResult, result
    assert result.success?
    assert_not_nil result.message
  end

  test "terminate sends SIGTERM to process group first" do
    pid = @mock_process_manager.spawn("test-command")

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    service.terminate

    # Verify SIGTERM was sent to process group
    assert @mock_process_manager.killed_processes.any? { |p| p[:signal] == "TERM" && p[:pid] == -pid }
  end

  test "terminate returns already_dead status when process not found via process_info" do
    service = ProcessTerminationService.new(
      process_pid: 99999,
      process_manager: @mock_process_manager
    )
    # process_info will return exists: false since ps won't find pid 99999

    result = service.terminate

    assert result.success?
    assert_equal :already_dead, result.status
  end

  test "terminate returns terminated status when process is successfully terminated" do
    pid = @mock_process_manager.spawn("test-command")

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    result = service.terminate

    assert result.success?
    assert_equal :terminated, result.status
  end

  test "terminate logs termination messages" do
    pid = @mock_process_manager.spawn("test-command")

    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager,
      session: session
    )

    service.terminate

    logs = session.logs
    assert logs.any? { |log| log.content.include?("Terminating process") }
    assert logs.any? { |log| log.content.include?("terminated successfully") }
  end

  test "terminate uses log buffer when provided" do
    pid = @mock_process_manager.spawn("test-command")

    mock_buffer = Object.new
    logged_messages = []
    mock_buffer.define_singleton_method(:add) do |content, level: "info"|
      logged_messages << { content: content, level: level }
    end

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager,
      log_buffer: mock_buffer
    )

    service.terminate

    assert logged_messages.any? { |log| log[:content].include?("Terminating process") }
    assert logged_messages.any? { |log| log[:content].include?("terminated successfully") }
  end

  test "terminate returns permission_denied status and never raises" do
    pid = @mock_process_manager.spawn("test-command")

    # Keep process "running" to simulate permission denied scenario
    # where we can't actually kill the process
    @mock_process_manager.running_hook = ->(check_pid) { check_pid == pid }
    model_liveness_faithfully(@mock_process_manager)

    @mock_process_manager.kill_hook = ->(signal, target_pid) {
      raise Errno::EPERM
    }

    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager,
      session: session
    )

    # Should not raise
    result = assert_nothing_raised { service.terminate }

    assert_not result.success?
    assert_equal :permission_denied, result.status
    assert session.logs.any? { |log| log.content.include?("Permission denied") }
  end

  test "terminate returns already_dead status when process_pid is nil" do
    service = ProcessTerminationService.new(
      process_pid: nil,
      process_manager: @mock_process_manager
    )

    result = service.terminate

    assert result.success?
    assert_equal :already_dead, result.status
    assert_match(/No process ID provided/, result.message)
  end

  # === Tests for process_info method ===

  test "process_info returns hash with expected keys" do
    service = ProcessTerminationService.new(
      process_pid: 99999,
      process_manager: @mock_process_manager
    )

    info = service.process_info

    assert_kind_of Hash, info
    assert info.key?(:exists)
    assert info.key?(:is_zombie)
    assert info.key?(:owned_by_us)
    assert info.key?(:uid)
    assert info.key?(:state)
  end

  test "process_info returns exists false for non-existent process" do
    service = ProcessTerminationService.new(
      process_pid: 99999,
      process_manager: @mock_process_manager
    )

    info = service.process_info

    assert_not info[:exists]
  end

  # === Tests for zombie process handling ===

  test "terminate handles zombie processes by reaping" do
    pid = @mock_process_manager.spawn("test-command")
    @mock_process_manager.set_process_state(pid, :zombie)

    mock_buffer = Object.new
    logged_messages = []
    mock_buffer.define_singleton_method(:add) do |content, level: "info"|
      logged_messages << { content: content, level: level }
    end

    service = ProcessTerminationService.new(
      process_pid: pid,
      process_manager: @mock_process_manager,
      log_buffer: mock_buffer
    )

    # Mock process_info to simulate zombie detection
    service.define_singleton_method(:process_info) do
      { exists: true, is_zombie: true, owned_by_us: true, uid: Process.uid, state: "Z" }
    end

    result = service.terminate

    assert result.success?
    assert_equal :zombie_reaped, result.status
    assert logged_messages.any? { |log| log[:content].include?("zombie") }
  end

  # === Tests for fallback termination strategies ===

  test "terminate falls back to individual process when group kill fails with ESRCH" do
    pid = @mock_process_manager.spawn("test-command")
    call_count = 0
    model_liveness_faithfully(@mock_process_manager)

    @mock_process_manager.kill_hook = ->(signal, target_pid) {
      call_count += 1
      if target_pid < 0
        # Process group kill - fail with ESRCH
        raise Errno::ESRCH
      else
        # Individual process kill - succeed
        @mock_process_manager.set_process_state(pid, :dead)
        1
      end
    }

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    result = service.terminate

    assert result.success?
    # Should have tried group first, then individual
    assert call_count >= 2
  end

  test "terminate falls back to individual process when group kill fails with EPERM" do
    pid = @mock_process_manager.spawn("test-command")
    group_kill_attempted = false
    model_liveness_faithfully(@mock_process_manager)

    @mock_process_manager.kill_hook = ->(signal, target_pid) {
      if target_pid < 0
        # Process group kill - fail with permission denied
        group_kill_attempted = true
        raise Errno::EPERM
      else
        # Individual process kill - succeed
        @mock_process_manager.set_process_state(pid, :dead)
        1
      end
    }

    mock_buffer = Object.new
    logged_messages = []
    mock_buffer.define_singleton_method(:add) do |content, level: "info"|
      logged_messages << { content: content, level: level }
    end

    service = ProcessTerminationService.new(
      process_pid: pid,
      process_manager: @mock_process_manager,
      log_buffer: mock_buffer
    )
    # Stub process_info
    service.define_singleton_method(:process_info) do
      { exists: true, is_zombie: false, owned_by_us: true, uid: Process.uid, state: "S" }
    end

    result = service.terminate

    assert result.success?
    assert group_kill_attempted
    # Should log that it tried group first
    assert logged_messages.any? { |log| log[:content].include?("Permission denied for process group") }
  end

  test "terminate escalates to SIGKILL when SIGTERM fails" do
    pid = @mock_process_manager.spawn("test-command")
    sigkill_sent = false

    # Keep process running until SIGKILL
    @mock_process_manager.running_hook = ->(check_pid) {
      !sigkill_sent && check_pid == pid
    }
    model_liveness_faithfully(@mock_process_manager)

    @mock_process_manager.kill_hook = ->(signal, target_pid) {
      if signal == "KILL"
        sigkill_sent = true
      end
      1
    }

    mock_buffer = Object.new
    logged_messages = []
    mock_buffer.define_singleton_method(:add) do |content, level: "info"|
      logged_messages << { content: content, level: level }
    end

    service = ProcessTerminationService.new(
      process_pid: pid,
      process_manager: @mock_process_manager,
      log_buffer: mock_buffer
    )
    # Stub process_info
    service.define_singleton_method(:process_info) do
      { exists: true, is_zombie: false, owned_by_us: true, uid: Process.uid, state: "S" }
    end

    result = service.terminate

    assert result.success?
    assert sigkill_sent
    assert logged_messages.any? { |log| log[:content].include?("SIGKILL") }
  end

  # === Tests for error handling ===

  test "terminate handles unexpected errors gracefully" do
    pid = @mock_process_manager.spawn("test-command")

    @mock_process_manager.kill_hook = ->(signal, target_pid) {
      raise StandardError, "Unexpected error"
    }

    service = ProcessTerminationService.new(
      process_pid: pid,
      process_manager: @mock_process_manager
    )
    # Stub process_info
    service.define_singleton_method(:process_info) do
      { exists: true, is_zombie: false, owned_by_us: true, uid: Process.uid, state: "S" }
    end

    result = assert_nothing_raised { service.terminate }

    assert_not result.success?
    assert_equal :error, result.status
    assert_match(/Unexpected error/, result.message)
  end

  # === Tests for process ownership detection ===

  test "terminate logs warning when process has different owner" do
    pid = @mock_process_manager.spawn("test-command")

    mock_buffer = Object.new
    logged_messages = []
    mock_buffer.define_singleton_method(:add) do |content, level: "info"|
      logged_messages << { content: content, level: level }
    end

    service = ProcessTerminationService.new(
      process_pid: pid,
      process_manager: @mock_process_manager,
      log_buffer: mock_buffer
    )

    # Stub process_info to return different owner
    service.define_singleton_method(:process_info) do
      { exists: true, is_zombie: false, owned_by_us: false, uid: 0, state: "S" }
    end

    service.terminate

    assert logged_messages.any? { |log| log[:level] == "warning" && log[:content].include?("different owner") }
  end

  # === Liveness must be answered by reaping, not by signal 0 (#280) ===
  #
  # `Process.kill(0, pid)` keeps succeeding for a child of ours that has already
  # exited: an unreaped child holds its pid as a zombie. These tests pin both
  # directions of that — a dead child must not read as alive, and a live child
  # must not read as dead.

  test "process_running? is false for an exited child even though signal 0 still succeeds" do
    pid = @mock_process_manager.spawn("test-command")
    # The zombie lie: signal-0 liveness says "running" forever...
    @mock_process_manager.running_hook = ->(_check_pid) { true }
    # ...while the child has in fact exited and is waiting to be collected.
    @mock_process_manager.wait_hook = ->(check_pid, _flags) { [ check_pid, MockProcessManager::MockStatus.new(0) ] }

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    assert_not service.send(:process_running?)
  end

  test "process_running? is true for a child that has not exited" do
    pid = @mock_process_manager.spawn("test-command")
    @mock_process_manager.running_hook = ->(_check_pid) { true }
    # WNOHANG on a child that is still running returns nil.
    @mock_process_manager.wait_hook = ->(_check_pid, _flags) { nil }

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    assert service.send(:process_running?)
  end

  test "process_running? falls back to signal 0 for a process that is not our child" do
    pid = @mock_process_manager.spawn("test-command")
    @mock_process_manager.wait_hook = ->(_check_pid, _flags) { raise Errno::ECHILD }

    @mock_process_manager.running_hook = ->(_check_pid) { true }
    alive_service = create_service_with_existing_process(pid: pid, process_manager: @mock_process_manager)
    assert alive_service.send(:process_running?), "ECHILD must not be read as 'process is gone'"

    @mock_process_manager.running_hook = ->(_check_pid) { false }
    dead_service = create_service_with_existing_process(pid: pid, process_manager: @mock_process_manager)
    assert_not dead_service.send(:process_running?)
  end

  test "process_running? stops probing a pid once it has been reaped" do
    pid = @mock_process_manager.spawn("test-command")
    liveness_probes = 0
    @mock_process_manager.running_hook = ->(_check_pid) {
      liveness_probes += 1
      true
    }
    waits = 0
    @mock_process_manager.wait_hook = ->(check_pid, _flags) {
      waits += 1
      [ check_pid, MockProcessManager::MockStatus.new(0) ]
    }

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    assert_not service.send(:process_running?)
    assert_not service.send(:process_running?)
    assert_not service.send(:process_running?)

    # The pid is released back to the OS on reap and may be recycled, so it must
    # never be probed again — by wait or by signal 0.
    assert_equal 1, waits
    assert_equal 0, liveness_probes
  end

  test "terminate returns terminated without escalating when the child dies on the first SIGTERM" do
    pid = @mock_process_manager.spawn("test-command")
    # Signal-0 liveness lies about the leader (zombie), the wait tells the truth.
    # Negative pids are group probes: this leader left no grandchildren behind.
    @mock_process_manager.running_hook = ->(check_pid) { !check_pid.negative? }
    @mock_process_manager.wait_hook = ->(check_pid, _flags) { [ check_pid, MockProcessManager::MockStatus.new(0) ] }

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = service.terminate
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal :terminated, result.status
    assert_operator elapsed, :<, 1.0, "a child that died on the first SIGTERM must not cost a full ladder"

    sigterms = @mock_process_manager.killed_processes.count { |p| p[:signal] == "TERM" }
    assert_equal 1, sigterms, "no redundant SIGTERM once the child is confirmed dead"
    assert_empty @mock_process_manager.killed_processes.select { |p| p[:signal] == "KILL" && p[:pid] == pid },
      "the leader must not be SIGKILLed after it is confirmed dead"
  end

  test "terminate logs to the Rails logger without raising when it has no buffer and no session" do
    pid = @mock_process_manager.spawn("test-command")

    service = ProcessTerminationService.new(
      process_pid: pid,
      process_manager: @mock_process_manager
    )
    # A different owner logs at "warning" — a Log level, not a Logger method.
    service.define_singleton_method(:process_info) do
      { exists: true, is_zombie: false, owned_by_us: false, uid: 0, state: "S" }
    end

    result = assert_nothing_raised { service.terminate }

    assert result.success?, "a NoMethodError from the logging fallback must not be reported as a failed kill"
  end

  # === Grandchild cleanup: the process group SIGKILL sweep ===

  test "terminate sweeps the process group with SIGKILL when members outlive the leader" do
    pid = @mock_process_manager.spawn("test-command")
    group_alive = true
    # Negative pids are group probes; the leader itself is gone.
    @mock_process_manager.running_hook = ->(check_pid) { check_pid.negative? ? group_alive : false }
    @mock_process_manager.kill_hook = ->(signal, target_pid) {
      group_alive = false if signal == "KILL" && target_pid.negative?
    }

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    result = service.terminate

    assert_equal :terminated, result.status
    assert @mock_process_manager.killed_processes.any? { |p| p[:signal] == "KILL" && p[:pid] == -pid },
      "grandchildren left in the group must get a SIGKILL sweep"
  end

  test "terminate does not signal the process group when it is already empty" do
    pid = @mock_process_manager.spawn("test-command")

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    result = service.terminate

    assert result.success?
    assert_empty @mock_process_manager.killed_processes.select { |p| p[:signal] == "KILL" },
      "an empty process group must not be signalled"
  end

  test "terminate never sweeps our own process group" do
    our_pgid = Process.getpgid(Process.pid)

    service = create_service_with_existing_process(
      pid: our_pgid,
      process_manager: @mock_process_manager
    )
    # Claim the group is alive; the guard, not the probe, has to be what stops us.
    @mock_process_manager.running_hook = ->(check_pid) { check_pid.negative? }

    service.terminate

    assert_empty @mock_process_manager.killed_processes.select { |p| p[:signal] == "KILL" && p[:pid] == -our_pgid },
      "SIGKILLing our own process group would kill this Ruby process"
  end

  test "a failing group sweep does not downgrade a successful termination" do
    pid = @mock_process_manager.spawn("test-command")
    @mock_process_manager.running_hook = ->(check_pid) { check_pid.negative? }
    @mock_process_manager.kill_hook = ->(signal, target_pid) {
      raise Errno::EPERM if signal == "KILL" && target_pid.negative?
    }

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    result = assert_nothing_raised { service.terminate }

    assert result.success?, "the leader is dead; a group we may not signal does not change that"
    assert_equal :terminated, result.status
  end

  test "terminate reaps a zombie and still sweeps its process group" do
    pid = @mock_process_manager.spawn("test-command")
    @mock_process_manager.set_process_state(pid, :zombie)
    group_alive = true
    @mock_process_manager.running_hook = ->(check_pid) { check_pid.negative? ? group_alive : true }
    @mock_process_manager.kill_hook = ->(signal, target_pid) {
      group_alive = false if signal == "KILL" && target_pid.negative?
    }

    service = ProcessTerminationService.new(
      process_pid: pid,
      process_manager: @mock_process_manager
    )
    service.define_singleton_method(:process_info) do
      { exists: true, is_zombie: true, owned_by_us: true, uid: Process.uid, state: "Z" }
    end

    result = service.terminate

    assert_equal :zombie_reaped, result.status
    assert @mock_process_manager.killed_processes.any? { |p| p[:signal] == "KILL" && p[:pid] == -pid },
      "a reaped zombie can still have live grandchildren in its group"
  end

  # === Real processes ===
  #
  # The mocked tests above pin the contract; these pin that the contract matches
  # what the kernel actually does. Both are needed: the defect in #280 was a real
  # kernel behaviour (signal 0 succeeding for an unreaped child) that no mock was
  # modelling.

  test "terminate kills a real child promptly, reports terminated, and leaves no zombie" do
    manager = SystemProcessManager.new
    pid = manager.spawn("sleep", "60", pgroup: true)
    wait_until(2.0) { real_process_state(pid).present? }

    service = ProcessTerminationService.new(process_pid: pid, process_manager: manager)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = service.terminate
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal :terminated, result.status,
      "a child that dies on SIGTERM must not report :error (it did, for ~15s, before #280)"
    assert result.success?
    assert_operator elapsed, :<, 5.0, "termination took #{elapsed.round(2)}s; the pre-#280 ladder took ~15-25s"

    # Not merely dead: collected. An unreaped child would still be listed as "Z".
    assert_empty real_process_state(pid).to_s,
      "the terminated child must be reaped, not left as a zombie"
  ensure
    force_cleanup(pid)
  end

  test "terminate SIGKILL-sweeps a real grandchild that ignores SIGTERM" do
    pidfile = Tempfile.new("zimmer-grandchild-pid")
    manager = SystemProcessManager.new
    # Leader is its own group leader (as agent children are, via pgroup: true).
    # The grandchild ignores SIGTERM, so only an explicit group SIGKILL removes it.
    script = %(sh -c 'trap "" TERM; sleep 60' & echo $! > #{pidfile.path}; sleep 60)
    pid = manager.spawn("sh", "-c", script, pgroup: true)

    grandchild_pid = nil
    wait_until(5.0) do
      grandchild_pid = pidfile.path.then { |p| File.read(p).strip }.to_i
      grandchild_pid.positive? && real_process_alive?(grandchild_pid)
    end
    assert grandchild_pid.to_i.positive?, "test setup: grandchild pid was never recorded"
    assert real_process_alive?(grandchild_pid), "test setup: grandchild was never running"

    result = ProcessTerminationService.new(process_pid: pid, process_manager: manager).terminate

    assert_equal :terminated, result.status
    wait_until(5.0) { !real_process_alive?(grandchild_pid) }
    assert_not real_process_alive?(grandchild_pid),
      "a grandchild that ignores SIGTERM must be swept with the group SIGKILL"
  ensure
    force_cleanup(grandchild_pid)
    force_cleanup(pid)
    pidfile&.close!
  end

  test "liveness of a real process that is not our child falls back to signal 0" do
    pidfile = Tempfile.new("zimmer-foreign-pid")
    manager = SystemProcessManager.new
    # Double-fork: the shell we spawn exits immediately, so the surviving sleep is
    # an orphan we did NOT spawn. Waiting on it raises ECHILD — which must not be
    # read as "gone", or a live process gets declared dead and its session stranded.
    script = %(sh -c 'sleep 60' & echo $! > #{pidfile.path})
    parent_pid = manager.spawn("sh", "-c", script)

    foreign_pid = nil
    wait_until(5.0) do
      foreign_pid = File.read(pidfile.path).strip.to_i
      foreign_pid.positive? && real_process_alive?(foreign_pid)
    end
    manager.wait(parent_pid) # collect the short-lived shell
    assert foreign_pid.to_i.positive?, "test setup: foreign pid was never recorded"
    assert real_process_alive?(foreign_pid), "test setup: foreign process was never running"

    service = ProcessTerminationService.new(process_pid: foreign_pid, process_manager: manager)

    assert_raises(Errno::ECHILD) { Process.wait2(foreign_pid, Process::WNOHANG) }
    assert service.send(:process_running?), "a live non-child must not be reported as gone"
  ensure
    force_cleanup(foreign_pid)
    force_cleanup(parent_pid)
    pidfile&.close!
  end

  test "terminate logs debug info when process owned by current user" do
    pid = @mock_process_manager.spawn("test-command")

    mock_buffer = Object.new
    logged_messages = []
    mock_buffer.define_singleton_method(:add) do |content, level: "info"|
      logged_messages << { content: content, level: level }
    end

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager,
      log_buffer: mock_buffer
    )

    service.terminate

    assert logged_messages.any? { |log| log[:level] == "debug" && log[:content].include?("owned by current user") }
  end
end
