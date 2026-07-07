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
# propagates Timeout::Error after the child is terminated). The consumer
# (HeadlessInferenceService) is responsible for turning failures into a nil
# result and logging — keeping that decision in one place across both backends.
class NativeClaudePrintRunner
  Error = Class.new(StandardError)

  # @param claude_binary [String] the binary to drive (injectable for tests)
  # @param model [String, nil] model id passed through as `--model`
  # @param process_manager [ProcessManager, nil] injectable for tests
  # @param logger [Logger]
  def initialize(claude_binary: "claude", model: nil, process_manager: nil, logger: Rails.logger)
    @claude_binary = claude_binary
    @model = model
    @process_manager = process_manager || SystemProcessManager.new
    @logger = logger
  end

  # Run one prompt through `claude -p` and return its stdout.
  #
  # @param prompt [String]
  # @param timeout [Integer] wall-clock budget in seconds
  # @return [ClaudePrintRunner::Result] text is the raw (unstripped) stdout;
  #   usage is nil (native print mode emits text only)
  # @raise [Error] on a blank prompt
  # @raise [Timeout::Error] if the call does not complete in time
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

  def terminate_process(pid)
    return unless pid

    @process_manager.kill("TERM", pid)
  rescue Errno::ESRCH
    # Process already terminated.
  rescue => e
    @logger.warn "[NativeClaudePrintRunner] failed to terminate process #{pid}: #{e.message}"
  end
end
