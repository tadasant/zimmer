# frozen_string_literal: true

require "tmpdir"
require "timeout"
require "fileutils"

# The native print-mode backend: shells out to `claude -p "<prompt>"`, waits for
# it to finish, and returns its stdout. This is Zimmer's default, historically
# proven headless-inference path; it is selected unless the
# `pty_transport` extension is enabled.
#
# Implements the ClaudePrintRunner contract:
#   #run(prompt:, timeout:) -> ClaudePrintRunner::Result
#
# Failure policy: structural problems raise (blank prompt → Error; a timeout
# propagates Timeout::Error after the child is terminated *and collected*, so a
# timed-out call leaves no defunct process behind). The consumer
# (HeadlessInferenceService) is responsible for turning failures into a nil
# result and logging — keeping that decision in one place across both backends.
class NativeClaudePrintRunner
  Error = Class.new(StandardError)

  # How long to poll for the child after each signal before escalating, and how
  # often to poll while doing so. The teardown reap runs after the run's own
  # Timeout budget is already spent, so it carries this bound of its own: a
  # child that answers neither signal costs the caller at most
  # 2 * (REAP_WINDOW + REAP_POLL_INTERVAL), since each window always makes one
  # final poll after its deadline passes.
  REAP_WINDOW = 1.0
  REAP_POLL_INTERVAL = 0.02

  # @param claude_binary [String] the binary to drive (injectable for tests)
  # @param model [String, nil] model id passed through as `--model`
  # @param process_manager [ProcessManager, nil] injectable for tests
  # @param logger [Logger]
  # @param reap_window [Float] per-signal reap bound in seconds (injectable for tests)
  # @param reap_poll_interval [Float] reap poll interval in seconds (injectable for tests)
  def initialize(claude_binary: "claude", model: nil, process_manager: nil, logger: Rails.logger,
                 reap_window: REAP_WINDOW, reap_poll_interval: REAP_POLL_INTERVAL)
    @claude_binary = claude_binary
    @model = model
    @process_manager = process_manager || SystemProcessManager.new
    @logger = logger
    @reap_window = reap_window
    @reap_poll_interval = reap_poll_interval
  end

  # Run one prompt through `claude -p` and return its stdout.
  #
  # @param prompt [String]
  # @param timeout [Integer] wall-clock budget in seconds
  # @return [ClaudePrintRunner::Result] text is the raw (unstripped) stdout;
  #   usage is nil (native print mode emits text only)
  # @raise [Error] on a blank prompt
  # @raise [Timeout::Error] if the call does not complete in time (raised after
  #   the child has been signalled and reaped)
  def run(prompt:, timeout:)
    raise Error, "prompt is blank" if prompt.to_s.strip.empty?

    pid = nil
    temp_dir = Dir.mktmpdir("headless_inference_")
    output_file = File.join(temp_dir, "output.txt")

    pid = @process_manager.spawn(
      *build_command(prompt),
      chdir: temp_dir,
      out: [ output_file, "w" ],
      err: File::NULL
    )

    Timeout.timeout(timeout) do
      @process_manager.wait(pid)
    end

    ClaudePrintRunner::Result.new(text: File.read(output_file), usage: nil)
  rescue Timeout::Error
    terminate_process(pid)
    raise
  ensure
    FileUtils.rm_rf(temp_dir) if temp_dir && Dir.exist?(temp_dir)
  end

  private

  def build_command(prompt)
    cmd = [ @claude_binary, "--dangerously-skip-permissions" ]
    # `--model` is omitted only when no model is supplied (a diagnostics-only
    # path), in which case `claude` inherits its own default. The production
    # consumer (HeadlessInferenceService) always pins a model, so the live path
    # never inherits the host default.
    cmd << "--model" << @model if @model.present?
    cmd << "-p" << prompt
    cmd
  end

  # Signal the timed-out child *and collect it*. The `Timeout` that brought us
  # here unwound the only blocking `wait`, so without a reap the child stays
  # defunct from the moment it dies until ZombieReaperJob's next tick.
  #
  # A plain blocking wait is the wrong fix: this path runs on a budget that is
  # already spent, and a child that ignores SIGTERM would hang the job (and, on
  # a busy queue, starve it). So the reap is bounded and non-blocking — poll
  # with WNOHANG for @reap_window after SIGTERM, escalate to SIGKILL, poll once
  # more. A child that survives both is left to the reaper, with a warning.
  def terminate_process(pid)
    return unless pid

    # The signal always goes first. Timeout delivers its exception at the next
    # safe point, so the blocking wait may already have collected the child — in
    # which case the signal raises ESRCH and the poll after it raises ECHILD,
    # both of which read as "collected". Polling first instead would put a
    # syscall that can fail between a live child and its SIGTERM.
    signal(pid, "TERM")
    return if reap(pid)

    signal(pid, "KILL")
    return if reap(pid)

    @logger.warn "[NativeClaudePrintRunner] process #{pid} still not collected after SIGKILL; " \
      "leaving it to ZombieReaperJob"
  rescue => e
    # Teardown failure must not replace the Timeout::Error the caller is waiting
    # for: HeadlessInferenceService distinguishes a timeout from a generic
    # failure by class.
    @logger.warn "[NativeClaudePrintRunner] failed to terminate process #{pid}: #{e.message}"
  end

  # Send a signal, tolerating the two ways it can fail on a child we still want
  # to collect: ESRCH (the pid is gone entirely — a zombie still accepts
  # signals) and EPERM. Either way the reap that follows is still worth doing.
  def signal(pid, name)
    @process_manager.kill(name, pid)
  rescue Errno::ESRCH
    # Process already terminated.
  rescue Errno::EPERM => e
    @logger.warn "[NativeClaudePrintRunner] cannot send SIG#{name} to process #{pid}: #{e.message}"
  end

  # Poll for the child with WNOHANG until it is collected or @reap_window expires.
  #
  # @return [Boolean] true once the child has been collected
  def reap(pid)
    deadline = monotonic_now + @reap_window

    loop do
      return true if collected?(pid)
      return false if monotonic_now >= deadline

      sleep @reap_poll_interval
    end
  end

  # One non-blocking wait.
  #
  # @return [Boolean] true if the child has been collected — by us, or by
  #   someone else: ZombieReaperJob's blanket `waitpid(-1)` races us here, and
  #   its win reaches us as ECHILD.
  def collected?(pid)
    !@process_manager.wait(pid, Process::WNOHANG).nil?
  rescue Errno::ECHILD
    true
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
